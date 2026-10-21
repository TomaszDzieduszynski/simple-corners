require_relative '../mesh_helpers'
M = MeshHelpers; V = M::V
# For convex inputs the result must stay convex: report the worst
# "dent" (a vertex outside the plane of a new face), relative to offset.
def dent(mesh, eng)
  used = {}
  M.result_polys(mesh, eng).each { |l| l.flatten.each { |i| used[i] = true } }
  pts = used.keys.map { |i| eng.points[i] }
  worst = 0.0; kind = nil
  eng.new_polys.each do |pl|
    q = pl[:ids].map { |i| eng.points[i] }
    nn = V.newell(q)
    area = V.len(nn) / 2
    $small = ($small || 0) + 1 if area < 0.01 * $off**2
    next if area < 0.01 * $off**2
    n = V.norm(nn)
    o = V.avg(q)
    pts.each { |p| d = V.dot(V.sub(p, o), n); (worst = d; kind = pl[:kind]) if d > worst }
  end
  [worst, kind]
end
[["M.pyramid", 1.0], ["M.pyramid", 2.0], ["M.box", 2.0], ["M.cylinder", 0.5]].each do |expr, off|
  [:round, :sharp].each do |mode|
    [4, 8].each do |n|
      mesh = eval(expr); $off = off; $small = 0
      e = M.run(mesh, M.edges(mesh), :mode => mode, :offset => off, :segments => n)
      w, k = dent(mesh, e)
      printf("%-10s off=%.1f %-5s n=%d  dent %.4f (%.1f%% of offset) in %s  [skipped %d tiny]\n", expr, off, mode, n, w, 100 * w / off, k.inspect, $small)
    end
  end
end
