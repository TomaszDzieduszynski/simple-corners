require_relative '../mesh_helpers'
M = MeshHelpers; V = M::V
def hull(pts)
  pts = pts.sort.uniq
  cross = lambda { |o, a, b| (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]) }
  lower = []; pts.each { |p| lower.pop while lower.size >= 2 && cross.call(lower[-2], lower[-1], p) <= 0; lower << p }
  upper = []; pts.reverse.each { |p| upper.pop while upper.size >= 2 && cross.call(upper[-2], upper[-1], p) <= 0; upper << p }
  lower[0...-1] + upper[0...-1]
end
rng = Random.new(7); worst = 0; ok = 0; big = 0
300.times do
  pts = (0...(5 + rng.rand(12))).map { [rng.rand * 20, rng.rand * 20] }
  poly = hull(pts)
  next if poly.size < 3
  mesh = M.prism(poly, 3 + 8 * rng.rand)
  all = M.edges(mesh); sel = all.select { rng.rand < 0.7 }; sel = all if sel.empty?
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  off = 0.2 + 0.6 * rng.rand
  begin
    e = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, :mode => mode, :offset => off * 3, :segments => 2 + rng.rand(7))
  rescue SimpleCorners::Core::Error
    big += 1; next
  end
  raise 'open' unless M.check_closed(mesh, e).empty?
  # every point inside the original convex solid
  d = 0
  e.points.each { |p| mesh.faces.each { |f| o = mesh.points[f[:loops][0][0]]; x = V.dot(V.sub(p, o), f[:normal]); d = x if x > d } }
  worst = [worst, d / off].max
  ok += 1
end
puts "ok=#{ok} too_large=#{big} worst outside/offset=#{worst.round(5)}"
