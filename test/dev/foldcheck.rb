require_relative '../mesh_helpers'
M = MeshHelpers; V = M::V
src = File.read(File.join(__dir__, 'dome.rb'))
eval(src[src.index('def icosphere'), src.index('mesh = icosphere') - src.index('def icosphere')])
def folds(mesh, eng)
  polys = M.result_polys(mesh, eng)
  nrm = polys.map { |lps| V.norm(V.newell(lps[0].map { |i| eng.points[i] })) }
  edge = Hash.new { |h, k| h[k] = [] }
  polys.each_with_index { |lps, pi| lps.each { |lp| lp.each_with_index { |a, i| edge[[a, lp[(i + 1) % lp.size]].sort] << pi } } }
  worst = 0; kinds = nil; at = nil
  edge.each do |k, ps|
    next unless ps.size == 2
    ang = Math.acos([[V.dot(nrm[ps[0]], nrm[ps[1]]), 1].min, -1].max) * 180 / Math::PI
    next unless eng.soft[k] || ps.all? { |q| q >= mesh.faces.size }
    if ang > worst
      worst = ang; at = eng.points[k[0]].map { |x| x.round(2) }
      kinds = ps.map { |q| q < mesh.faces.size ? :face : eng.new_polys[q - mesh.faces.size][:kind] }
    end
  end
  [worst.round(1), kinds, at]
end
mesh = icosphere(4, 20.0)
rng = Random.new(3)
worst_all = []
[1, 2, 3, 6, 10].each do |nf|
  [:round, :sharp, :bevel].each do |mode|
    5.times do
      f0 = mesh.faces[rng.rand(mesh.faces.size)]
      sf = [f0]
      while sf.size < nf
        c = mesh.faces.select { |f| !sf.include?(f) && sf.any? { |s| (s[:loops][0] & f[:loops][0]).size == 2 } }.sample(random: rng)
        sf << c
      end
      sel = sf.flat_map { |f| l = f[:loops][0]; (0...l.size).map { |i| [l[i], l[(i + 1) % l.size]].sort } }.uniq
      e = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, :mode => mode, :offset => 1.2, :segments => 6)
      raise 'open' unless M.check_closed(mesh, e).empty?
      w = folds(mesh, e)
      worst_all << [w[0], nf, mode, w[1], w[2]]
    end
  end
end
worst_all.sort_by { |x| -x[0] }.first(8).each { |x| p x }
