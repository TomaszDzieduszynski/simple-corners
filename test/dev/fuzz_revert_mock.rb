# Stress test of the Revert to sharp edge command on the mock SketchUp API:
# random solids are rounded with the real command, the new surface is
# selected (all of it, or a random part) and reverted with the real command.
# Expected: the original solid back (whole surface), or a valid closed solid
# (part), or a refusal that leaves the model exactly as it was.
# Usage: ruby test/dev/fuzz_revert_mock.rb [rounds]   (default 200)
require_relative '../mock_sketchup'
require_relative '../mesh_helpers'
Sketchup.model = Sketchup::Model.new
load File.expand_path('../../src/simple_corners.rb', __dir__)
SimpleCorners.define_singleton_method(:notify) { |_m| nil }

M = MeshHelpers
V = SimpleCorners::Core::V
SC = SimpleCorners
ROUNDS = (ARGV[0] || 200).to_i

# Solids without holes (the mock cannot make faces with holes).
def random_mesh(rng)
  case rng.rand(7)
  when 0 then M.box(1 + 20 * rng.rand, 1 + 20 * rng.rand, 1 + 20 * rng.rand)
  when 1 then M.lshape
  when 2 then M.cylinder(3 + rng.rand(30), 1 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 3 then M.pyramid(2 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 4 then M.frustum(5 + rng.rand(12), 10, 2 + 7 * rng.rand, 5 + 20 * rng.rand, 10 * rng.rand - 5)
  else
    n = 3 + rng.rand(10)
    poly = (0...n).map do |i|
      a = 2 * Math::PI * (i + 0.45 * rng.rand) / n
      r = 2 + 10 * rng.rand
      [r * Math.cos(a), r * Math.sin(a)]
    end
    M.prism(poly, 0.5 + 10 * rng.rand)
  end
end

def model
  Sketchup.active_model
end

def faces
  model.entities.grep(Sketchup::Face)
end

def volume
  faces.inject(0.0) do |vol, f|
    p = f.vertices.map { |v| v.position.to_a }
    (1...p.size - 1).inject(vol) { |s, i| s + V.dot(p[0], V.cross(p[i], p[i + 1])) / 6.0 }
  end
end

def closed?
  model.entities.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 }
end

# Closed once points closer than SketchUp's tolerance (0.001") are merged,
# as SketchUp does and the mock does not.
def closed_merged?
  pts = model.entities.grep(Sketchup::Edge).flat_map { |e| [e.start, e.end] }.uniq
  id = {}
  pts.each { |v| id[v] = pts.index { |w| w.position.distance(v.position) < 0.001 } }
  uses = Hash.new(0)
  faces.each do |f|
    vs = f.vertices.map { |v| id[v] }
    vs.each_index do |i|
      a = vs[i]
      b = vs[(i + 1) % vs.size]
      uses[[a, b].sort] += 1 unless a == b
    end
  end
  uses.values.all?(&:even?)
end

def snapshot
  faces.map { |f| f.vertices.map { |v| v.position.to_a.map { |c| c.round(6) } }.sort }.sort
end

bugs = Hash.new { |h, k| h[k] = [] }
stats = Hash.new(0)
rng = Random.new((ENV['SEED'] || 1).to_i)
ONLY = ENV['ONLY'] ? ENV['ONLY'].to_i : nil
ROUNDS.times do |it|
  Sketchup.model = Sketchup::Model.new
  $trace = ONLY == it
  UI.messages.clear
  mesh = random_mesh(rng)
  mesh.faces.each { |f| model.entities.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*mesh.points[i]) }) }
  n0 = faces.size
  v0 = volume
  edges = model.entities.grep(Sketchup::Edge)
  sel = rng.rand < 0.4 ? edges : edges.select { rng.rand < 0.5 }
  sel = [edges[rng.rand(edges.size)]] if sel.empty?
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  SC::Settings.segments = 1 + rng.rand(8)
  SC::Settings.smooth = rng.rand < 0.8
  r = 0.1 + 2 * rng.rand
  desc = "round #{it} #{mode} r=#{r.round(3)} seg=#{SC::Settings.segments} smooth=#{SC::Settings.smooth?} edges=#{sel.size}"
  model.selection.add(sel)
  next unless SC.apply(mode, r, true)
  # the mock does not merge points closer than SketchUp's tolerance, so a
  # rounding can leave tiny gaps that SketchUp would close: skip those
  unless closed?
    stats[:skipped_rounding_open] += 1
    next
  end
  surf = faces.select { |f| f.get_attribute('SimpleCorners', 'op') }
  next if surf.empty?
  part = rng.rand < 0.3
  pick = part ? surf.select { rng.rand < 0.5 } : surf
  next if pick.empty?
  model.selection.clear
  model.selection.add(pick)
  before = snapshot
  vb = volume
  UI.messages.clear
  if $trace && !SC::Resharpen.respond_to?(:orig_solve_f)
    SC::Resharpen.singleton_class.send(:alias_method, :orig_solve_f, :solve)
    SC::Resharpen.define_singleton_method(:solve) do |*a|
      begin
        orig_solve_f(*a)
      rescue SC::Resharpen::Error => e
        puts "network refused (#{a[2].size} faces): #{e.message}" if $trace
        File.binwrite(ENV['DUMP_TO'], Marshal.dump(a)) if $trace && ENV['DUMP_TO'] && !File.exist?(ENV['DUMP_TO'])
        raise
      end
    end
  end
  kinds = []
  unless SC::Unround.respond_to?(:orig_plan_f)
    SC::Unround.singleton_class.send(:alias_method, :orig_plan_f, :plan)
    SC::Unround.define_singleton_method(:plan) { |fs| r = orig_plan_f(fs); ($kinds ||= []) << r[:kind]; r }
    SC::Unround.singleton_class.send(:alias_method, :orig_commit_f, :commit)
    SC::Unround.define_singleton_method(:commit) do |ents, job|
      r = orig_commit_f(ents, job)
      if $trace
        open = ents.grep(Sketchup::Edge).reject { |e| e.faces.size == 2 }
        puts "after #{job[:kind]} (#{job[:faces].size} faces): #{open.size} open edges #{open.first(2).map { |e| [e.start.position.to_a.map { |c| c.round(4) }, e.end.position.to_a.map { |c| c.round(4) }] }.inspect}"
      end
      r
    end
  end
  $kinds = []
  begin
    ok = SC::Unround.run
  rescue StandardError => e
    bugs["#{e.class}: #{e.message[0, 80]} @ #{e.backtrace[0]}"] << desc
    next
  end
  log = UI.messages.grep(/failed/)
  bugs["unexpected error: #{log.first[0, 90]}"] << desc unless log.empty?
  if !ok
    stats[part ? :part_refused : :refused] += 1
    bugs['refused but the model changed'] << "#{desc} via #{$kinds.inspect} #{UI.messages.last}" unless snapshot == before && (volume - vb).abs < 1e-9
    bugs['refused without undo'] << desc unless model.ops.last == [:abort]
  elsif !closed? && closed_merged?
    # a rounding again left a gap SketchUp would close (see above)
    stats[:skipped_rounding_open] += 1
  elsif !closed?
    open = model.entities.grep(Sketchup::Edge).reject { |e| e.faces.size == 2 }
    bugs["#{part ? 'part' : 'whole'}: result not closed"] << "#{desc} via #{$kinds.inspect} open: #{open.first(2).map { |e| [e.start.position.to_a.map { |c| c.round(3) }, e.end.position.to_a.map { |c| c.round(3) }, e.faces.size] }.inspect}"
  elsif part
    stats[:part_ok] += 1
  elsif UI.messages.empty? && (faces.size != n0 || (volume - v0).abs > 1e-6 * (1 + v0.abs))
    bugs["whole: wrong result"] << "#{desc} via #{$kinds.inspect} faces #{faces.size}/#{n0} volume #{volume.round(4)}/#{v0.round(4)}"
  else
    stats[UI.messages.empty? ? :exact : :partly] += 1
  end
end
puts "stats: #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}"
if bugs.empty?
  puts 'no bugs'
else
  bugs.each { |m, l| puts "#{l.size} x #{m}\n    e.g. #{l.first(3).join("\n         ")}" }
  exit 1
end
