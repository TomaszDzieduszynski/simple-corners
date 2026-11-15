# Corner families: random solids made of the corners where two fillets meet
# at an edge that stays sharp and cross it at different heights (convex:
# prisms with a tilted top; concave: pockets with a tilted floor, like a
# sill in an opening). For each case, the engine result must be closed and
# flat, keep every radius constant (nothing in a face comes closer to a
# selected edge than its radius), and, where only those corners occur, be
# made of fillet strips only (no filler patches); the real Round command on
# the mock API, then Revert, must give the original solid back (or refuse
# and leave the model as it was).
# Usage: ruby test/dev/fuzz_corners.rb [rounds]   (default 200)
require_relative '../mock_sketchup'
require_relative '../mesh_helpers'
Sketchup.model = Sketchup::Model.new
load File.expand_path('../../src/simple_corners.rb', __dir__)
SimpleCorners.define_singleton_method(:notify) { |_m| nil }

M = MeshHelpers
V = SimpleCorners::Core::V
SC = SimpleCorners
ROUNDS = (ARGV[0] || 200).to_i
rng = Random.new((ENV['SEED'] || 1).to_i)

# Prism over a random star-shaped polygon, its top on a tilted plane.
# Returns [mesh, top edges].
def tilted_prism(rng)
  n = 3 + rng.rand(10)
  poly = (0...n).map do |i|
    a = 2 * Math::PI * (i + 0.4 * rng.rand) / n
    r = 4 + 6 * rng.rand
    [r * Math.cos(a), r * Math.sin(a)]
  end
  h = 8 + 6 * rng.rand
  ax = (rng.rand - 0.5) * 1.2
  ay = (rng.rand - 0.5) * 1.2
  pts = poly.map { |x, y| [x, y, 0.0] } + poly.map { |x, y| [x, y, h + ax * x + ay * y] }
  faces = [M.face([(0...n).to_a.reverse], pts), M.face([(n...2 * n).to_a], pts)]
  n.times do |i|
    j = (i + 1) % n
    faces << M.face([[i, j, n + j, n + i]], pts)
  end
  [M::Mesh.new(pts, faces), (0...n).map { |i| [n + i, n + (i + 1) % n] }]
end

# Block 0..12 x 0..12 x 0..10 with a rectangular pocket from the top, its
# floor on a tilted plane. Returns [mesh, floor edges].
def pocket(rng)
  x1 = 2 + 3 * rng.rand
  x2 = 7 + 3 * rng.rand
  y1 = 2 + 3 * rng.rand
  y2 = 7 + 3 * rng.rand
  f = 3 + 3 * rng.rand
  ax = (rng.rand - 0.5) * 0.8
  ay = (rng.rand - 0.5) * 0.8
  fz = lambda { |x, y| f + ax * (x - 6) + ay * (y - 6) }
  outer = [[0, 0], [12, 0], [12, 12], [0, 12]]
  hole = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
  pts = outer.map { |x, y| [x, y, 0.0] } + outer.map { |x, y| [x, y, 10.0] } +
        hole.map { |x, y| [x, y, 10.0] } + hole.map { |x, y| [x, y, fz.call(x, y)] }
  pts = pts.map { |p| p.map(&:to_f) }
  faces = []
  faces << M.face([[3, 2, 1, 0]], pts) # bottom
  faces << M.face([[4, 5, 6, 7], [11, 10, 9, 8]], pts) # top with the pocket as a hole
  4.times do |i|
    j = (i + 1) % 4
    faces << M.face([[i, j, 4 + j, 4 + i]], pts) # outer sides
    faces << M.face([[8 + i, 8 + j, 12 + j, 12 + i]], pts) # pocket walls
  end
  faces << M.face([[12, 13, 14, 15]], pts) # pocket floor
  [M::Mesh.new(pts, faces), (0...4).map { |i| [12 + i, 12 + (i + 1) % 4] }]
end

# Distance of p from the edge a-b across it, or nil if p does not lie
# alongside the edge (its projection falls outside it: a corner).
def seg_dist(p, a, b)
  ab = V.sub(b, a)
  t = V.dot(V.sub(p, a), ab) / V.dot(ab, ab)
  return nil if t <= 1e-9 || t >= 1 - 1e-9
  V.dist(p, V.add(a, V.mul(ab, t)))
end

# Nothing in a face comes closer to one of its selected edges than that
# edge's radius. Returns the worst shortfall (relative), or 0.
def taper(mesh, eng, sel, r)
  worst = 0.0
  keys = sel.map { |a, b| a < b ? [a, b] : [b, a] }
  eng.face_loops.each do |fi, loops|
    flp = mesh.faces[fi][:loops]
    own = keys.select { |a, b| flp.any? { |lp| lp.each_index.any? { |i| [lp[i], lp[(i + 1) % lp.size]].sort == [a, b] } } }
    next if own.empty?
    # (ends of fillets running on past a mitre lie on that fillet: skipped)
    skip = {}
    eng.run_on_ids.each { |v| skip[v] = true }
    news = loops.flatten.uniq.select { |v| v >= mesh.points.size && !skip[v] }
    own.each do |k|
      rk = eng.reduced[k] || r
      news.each do |v|
        dd = seg_dist(eng.points[v], mesh.points[k[0]], mesh.points[k[1]])
        next unless dd
        short = (rk - dd) / rk
        worst = short if short > worst
      end
    end
  end
  worst
end

# The farthest a new outline point lies from every selected edge, in
# radii: fillets must stay near their edges (no spikes along other edges).
def spike(mesh, eng, sel, r)
  worst = 0.0
  segs = sel.map { |a, b| k = a < b ? [a, b] : [b, a]; [mesh.points[a], mesh.points[b], eng.reduced[k] || r] }
  eng.face_loops.each_value do |loops|
    loops.flatten.uniq.select { |v| v >= mesh.points.size }.each do |v|
      p = eng.points[v]
      dd = segs.map do |a, b, rk|
        ab = V.sub(b, a)
        t = [[V.dot(V.sub(p, a), ab) / V.dot(ab, ab), 0.0].max, 1.0].min
        V.dist(p, V.add(a, V.mul(ab, t))) / rk
      end.min
      worst = dd if dd > worst
    end
  end
  worst
end

def build(model, mesh)
  ents = model.entities
  gp = lambda { |i| Geom::Point3d.new(*mesh.points[i]) }
  mesh.faces.sort_by { |f| -f[:loops].size }.each do |f|
    face = ents.add_face(f[:loops][0].map(&gp))
    face.inside = nil
    face.reverse! if face.normal.dot(Geom::Vector3d.new(*f[:normal])) < 0
    f[:loops][1..-1].each do |lp|
      hf = ents.add_face(lp.map(&gp))
      hf.inside = face
      hf.erase!
    end
  end
end

def snapshot(model)
  key = lambda { |p| p.to_a.map { |x| x.round(6) } }
  fs = model.entities.grep(Sketchup::Face).map { |f| f.vertices.map { |v| key.call(v.position) }.sort }.sort
  es = model.entities.grep(Sketchup::Edge).map { |e| [key.call(e.start.position), key.call(e.end.position)].sort }.sort
  [fs, es]
end

def closed?(model)
  model.entities.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 }
end

bugs = Hash.new { |h, k| h[k] = [] }
stats = Hash.new(0)
ROUNDS.times do |it|
  family = it.even? ? :prism : :pocket
  mesh, special = family == :prism ? tilted_prism(rng) : pocket(rng)
  all = M.edges(mesh)
  only_special = rng.rand < 0.6
  sel = only_special ? special : all.select { rng.rand < 0.5 }
  sel = special if sel.empty?
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  r = 0.2 + 1.3 * rng.rand
  segs = 1 + rng.rand(8)
  desc = "round #{it} #{family} #{mode} r=#{r.round(3)} seg=#{segs} #{only_special ? 'special' : 'random'} sel=#{sel.size}"
  if ENV['DUMP_ROUND'] && ENV['DUMP_ROUND'].to_i == it
    File.write(ENV['DUMP_ROUND_TO'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
  end
  # 1. engine
  begin
    eng = SC::Core::Engine.fit(mesh.points, mesh.faces, sel, :mode => mode, :offset => r, :segments => segs)
    probs = M.check_closed(mesh, eng)
    bugs['engine: not closed'] << desc unless probs.empty?
    bugs['engine: non-planar polygons'] << desc unless M.nonplanar(mesh, eng).empty?
    bugs['engine: NaN'] << desc if eng.points.any? { |p| p.any? { |x| x.nan? || x.infinite? } }
    tp = taper(mesh, eng, sel, r)
    if tp > 1e-6 && !eng.mitre_fallbacks.empty?
      stats[:taper_at_fallback] += 1
      stats[:worst_fallback_taper_pct] = [stats[:worst_fallback_taper_pct], (tp * 100).round(2)].max
    elsif tp > 1e-6
      if ENV['DUMP2'] && !$dumped2
        $dumped2 = true
        File.write(ENV['DUMP2'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
      end
      bugs['engine: radius not constant (taper)'] << "#{desc} by #{(tp * 100).round(2)}%"
    end
    stats[:fallback_corners] += eng.mitre_fallbacks.size
    stats[:capped_corners] += eng.capped.size
    eng.mitre_fallbacks.each do |v|
      ks = sel.map { |x, y| x < y ? [x, y] : [y, x] }.select { |k| k.include?(v) }
      next unless ks.size == 2
      ds = ks.map { |k| o = k[0] == v ? k[1] : k[0]; V.norm(V.sub(mesh.points[o], mesh.points[v])) }
      ang = Math.acos([[V.dot(ds[0], ds[1]), 1.0].min, -1.0].max) * 180 / Math::PI
      ($fb_angles ||= []) << ang.round
      if ang < 125 && ENV['DUMP_FB'] && !$dumped_fb
        $dumped_fb = true
        File.write(ENV['DUMP_FB'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc, :v => v }.inspect)
      end
    end
    if tp > 1e-6 && ENV['DUMP'] && !$dumped
      $dumped = true
      File.write(ENV['DUMP'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
    end
    sp = spike(mesh, eng, sel, r)
    bugs['engine: spike (outline point far from every selected edge)'] << "#{desc} at #{sp.round(2)} radii" if sp > 1.5
    if mode != :bevel
      sd, se = M.section_depth(mesh, eng, sel, r, segs)
      stats[:worst_section_pct] = [stats[:worst_section_pct] == 0 ? 100.0 : stats[:worst_section_pct], (sd * 100).round(1)].min
      bugs['engine: twisted strip (section dips inside the fillet)'] << "#{desc} edge #{se.inspect} at #{(sd * 100).round(1)}%" if sd < 0.95
      if sd < 0.95 && ENV['DUMP_SEC'] && !$dumped_sec
        $dumped_sec = true
        File.write(ENV['DUMP_SEC'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
      end
    end
    stats[:engine_ok] += 1
    stats[:reduced] += 1 unless eng.reduced.empty?
  rescue SC::Core::Error
    stats[:engine_refused] += 1
    next
  rescue StandardError => e
    bugs["engine: #{e.class}: #{e.message[0, 80]} @ #{e.backtrace[0]}"] << desc
    next
  end
  # 2. Round and Revert on the mock API
  begin
    Sketchup.model = model = Sketchup::Model.new
    UI.messages.clear
    build(model, mesh)
    before = snapshot(model)
    pos = sel.map { |a, b| [mesh.points[a], mesh.points[b]] }
    model.entities.grep(Sketchup::Edge).each do |e|
      ab = [e.start.position.to_a, e.end.position.to_a]
      model.selection.add(e) if pos.any? { |p, q| (V.dist(p, ab[0]) < 1e-9 && V.dist(q, ab[1]) < 1e-9) || (V.dist(p, ab[1]) < 1e-9 && V.dist(q, ab[0]) < 1e-9) }
    end
    SC::Settings.segments = segs
    unless SC.apply(mode, r)
      bugs['ui: refused but the model changed'] << "#{desc} #{UI.messages.last}" unless snapshot(model) == before
      if snapshot(model) != before && ENV['DUMP_UI'] && !$dumped_ui
        $dumped_ui = true
        File.write(ENV['DUMP_UI'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
      end
      stats[:ui_refused] += 1
      next
    end
    bugs['ui: rounded model not closed'] << desc unless closed?(model)
    if !closed?(model) && ENV['DUMP_NC'] && !$dumped_nc
      $dumped_nc = true
      File.write(ENV['DUMP_NC'], { :points => mesh.points, :faces => mesh.faces, :sel => sel, :mode => mode, :r => r, :segs => segs, :desc => desc }.inspect)
      model.entities.grep(Sketchup::Edge).select { |e| e.faces.size != 2 }.first(8).each { |e| puts "  edge #{e.start.position.to_a.map { |x| x.round(4) }} - #{e.end.position.to_a.map { |x| x.round(4) }} faces #{e.faces.size} #{e.faces.map { |f| f.get_attribute('SimpleCorners', 'op') ? 'new' : 'orig' }.inspect}" }
    end
    tagged = model.entities.grep(Sketchup::Face).select { |f| f.get_attribute('SimpleCorners', 'op') }
    model.selection.clear
    model.selection.add(tagged)
    if SC::Unround.run
      if snapshot(model) == before
        stats[:revert_exact] += 1
      else
        bugs['ui: revert did not give the original back'] << desc unless closed?(model)
        stats[:revert_other] += 1
      end
    else
      stats[:revert_refused] += 1
    end
    if ENV['REVERT_LOG']
      outcome = stats[:revert_exact] + stats[:revert_other] + stats[:revert_refused]
      File.open(ENV['REVERT_LOG'], 'a') do |f|
        f.puts "#{desc}: exact=#{stats[:revert_exact]} other=#{stats[:revert_other]} refused=#{stats[:revert_refused]} (#{outcome}) " +
               UI.messages.last(2).map { |m| m.to_s[0, 140].tr("\n", ' ') }.join(' | ')
      end
    end
    msgs = UI.messages.select { |m| m.to_s =~ /failed/ }
    msgs.each { |m| bugs["ui message: #{m.to_s[0, 90]}"] << desc }
  rescue StandardError => e
    bugs["ui: #{e.class}: #{e.message[0, 80]} @ #{e.backtrace[0]}"] << desc
  end
end

puts "angles between the two edges at fallback corners: min #{($fb_angles || [0]).min} max #{($fb_angles || [0]).max} deg; histogram #{($fb_angles || []).group_by { |x| (x / 10) * 10 }.map { |k, v| [k, v.size] }.sort.inspect}" if $fb_angles
puts "stats: #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}"
if bugs.empty?
  puts 'no bugs'
else
  bugs.each { |k, v| puts "#{v.size} x #{k}\n    e.g. #{v.first(2).join(' | ')}" }
end
