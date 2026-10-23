# Stress test of reverting part of a rounded network (mock SketchUp API):
# random solids get a set of edges rounded (one operation, random mode);
# the faces of a random subset of those edges are selected and reverted.
# Expected: the same solid as rounding only the other edges (same face
# count and volume, closed), or a refusal that leaves the model as it was.
# Cases where the first rounding reduced the radius are skipped (the other
# edges then rightly keep their reduced radius). "close": same faces, volume
# within 0.01% (a corner patch where several fillets meet is built from the
# faces in another order, so its inner points differ slightly).
# Usage: ruby test/dev/fuzz_partial_mock.rb [rounds]   (default 150)
require_relative '../mock_sketchup'
require_relative '../mesh_helpers'
Sketchup.model = Sketchup::Model.new
load File.expand_path('../../src/simple_corners.rb', __dir__)
$notes = []
SimpleCorners.define_singleton_method(:notify) { |m| $notes << m }

M = MeshHelpers
V = SimpleCorners::Core::V
SC = SimpleCorners
ROUNDS = (ARGV[0] || 150).to_i

def random_mesh(rng)
  case rng.rand(6)
  when 0 then M.box(4 + 16 * rng.rand, 4 + 16 * rng.rand, 4 + 16 * rng.rand)
  when 1 then M.lshape
  when 2 then M.cylinder(5 + rng.rand(10), 5 + 5 * rng.rand, 4 + 6 * rng.rand)
  when 3 then M.pyramid(6 + 6 * rng.rand, 4 + 6 * rng.rand)
  else
    n = 3 + rng.rand(6)
    poly = (0...n).map do |i|
      a = 2 * Math::PI * (i + 0.3 * rng.rand) / n
      r = 6 + 4 * rng.rand
      [r * Math.cos(a), r * Math.sin(a)]
    end
    M.prism(poly, 3 + 6 * rng.rand)
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

def seg_dist(p, a, b)
  ab = V.sub(b, a)
  t = [[V.dot(V.sub(p, a), ab) / V.dot(ab, ab), 0.0].max, 1.0].min
  V.dist(p, V.add(a, V.mul(ab, t)))
end

# Builds the mesh, rounds the edges (point pairs); returns false if the
# rounding failed or reduced the radius.
def make(mesh, edges, mode, r)
  Sketchup.model = Sketchup::Model.new
  mesh.faces.each { |f| model.entities.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*mesh.points[i]) }) }
  return true if edges.empty?
  sel = model.entities.grep(Sketchup::Edge).select do |e|
    edges.any? { |a, b| [a, b].sort == [e.start.position.to_a, e.end.position.to_a].sort }
  end
  model.selection.add(sel)
  $notes.clear
  ok = SC.apply(mode, r, true)
  model.selection.clear
  ok && $notes.none? { |m| m =~ /reduced/ } && closed?
end

def snapshot
  faces.map { |f| f.vertices.map { |v| v.position.to_a.map { |c| c.round(6) } }.sort }.sort
end

bugs = Hash.new { |h, k| h[k] = [] }
stats = Hash.new(0)
rng = Random.new((ENV['SEED'] || 1).to_i)
ROUNDS.times do |it|
  mesh = random_mesh(rng)
  all = M.edges(mesh).map { |a, b| [mesh.points[a], mesh.points[b]] }
  rounded = rng.rand < 0.5 ? all : all.select { rng.rand < 0.6 }
  next if rounded.size < 2
  back = rounded.select { rng.rand < 0.4 }
  back = [rounded[rng.rand(rounded.size)]] if back.empty?
  next if back.size == rounded.size
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  SC::Settings.segments = 1 + rng.rand(6)
  SC::Settings.smooth = rng.rand < 0.8
  r = 0.3 + 1.2 * rng.rand
  desc = "round #{it} #{mode} r=#{r.round(3)} seg=#{SC::Settings.segments} smooth=#{SC::Settings.smooth?} edges=#{back.size}/#{rounded.size}/#{all.size}"
  unless make(mesh, rounded - back, mode, r)
    stats[:skipped] += 1
    next
  end
  want = [faces.size, volume]
  unless make(mesh, rounded, mode, r)
    stats[:skipped] += 1
    next
  end
  pick = faces.select do |f|
    next false unless f.get_attribute('SimpleCorners', 'op')
    c = V.avg(f.vertices.map { |v| v.position.to_a })
    back.include?(rounded.min_by { |a, b| seg_dist(c, a, b) })
  end
  next if pick.empty?
  model.selection.add(pick)
  before = snapshot
  UI.messages.clear
  begin
    ok = SC::Unround.run
  rescue StandardError => e
    bugs["#{e.class}: #{e.message[0, 80]} @ #{e.backtrace[0]}"] << desc
    next
  end
  log = UI.messages.grep(/failed/)
  bugs["unexpected error: #{log.first[0, 90]}"] << desc unless log.empty?
  if !ok
    stats[:refused] += 1
    bugs['refused but the model changed'] << "#{desc}: #{UI.messages.last}" unless snapshot == before
  elsif !closed?
    bugs['result not closed'] << desc
  elsif faces.size == want[0] && (volume - want[1]).abs <= 1e-6 * (1 + want[1].abs)
    stats[:exact] += 1
  elsif faces.size == want[0] && (volume - want[1]).abs <= 1e-4 * (1 + want[1].abs)
    # same faces, corner patches built in a different order: inner points
    # of a patch where several fillets meet differ slightly
    stats[:close] += 1
  else
    bugs['different from rounding only the other edges'] << "#{desc} faces #{faces.size}/#{want[0]} volume #{volume.round(4)}/#{want[1].round(4)} #{UI.messages.last}"
  end
end
puts "stats: #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}"
if bugs.empty?
  puts 'no bugs'
else
  bugs.each { |m, l| puts "#{l.size} x #{m}\n    e.g. #{l.first(3).join("\n         ")}" }
  exit 1
end
