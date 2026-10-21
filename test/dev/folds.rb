require_relative '../mesh_helpers'
M = MeshHelpers; V = M::V
def folds(mesh, eng)
  polys = M.result_polys(mesh, eng)
  nrm = polys.map { |lps| V.norm(V.newell(lps[0].map { |i| eng.points[i] })) }
  edge = Hash.new { |h, k| h[k] = [] }
  polys.each_with_index { |lps, pi| lps.each { |lp| lp.each_with_index { |a, i| b = lp[(i + 1) % lp.size]; edge[[a, b].sort] << pi } } }
  worst = 0; where = nil
  edge.each do |k, ps|
    next unless ps.size == 2 && eng.soft[k]
    ang = Math.acos([[V.dot(nrm[ps[0]], nrm[ps[1]]), 1].min, -1].max) * 180 / Math::PI
    (worst = ang; where = [ps.map { |q| q < mesh.faces.size ? :face : eng.new_polys[q - mesh.faces.size][:kind] }, k.map { |i| eng.points[i].map { |x| x.round(2) } }]) if ang > worst
  end
  [worst.round(1), where]
end
[["M.pyramid", 1.0], ["M.pyramid", 2.0], ["M.box", 2.0], ["M.lshape", 2.0]].each do |expr, off|
  [6, 8].each do |n|
    mesh = eval(expr)
    e = M.run(mesh, M.edges(mesh), :mode => (ENV["MODE"] || "round").to_sym, :offset => off, :segments => n)
    w, at = folds(mesh, e)
    puts "#{expr} off=#{off} n=#{n}: worst soft dihedral #{w} deg at #{at.inspect}"
  end
end
