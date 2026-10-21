require_relative '../mesh_helpers'
M = MeshHelpers
fails = Hash.new(0); ok = 0; big = 0
[1, 2, 3].each do |seed|
  rng = Random.new(seed)
  200.times do |iter|
    n = 3 + rng.rand(9)
    poly = (0...n).map { |i| a = 2 * Math::PI * (i + 0.4 * rng.rand) / n; r = 4 + 8 * rng.rand; [r * Math.cos(a), r * Math.sin(a)] }
    mesh = M.prism(poly, 3 + 8 * rng.rand)
    all = M.edges(mesh)
    sel = all.select { rng.rand < 0.5 + 0.5 * rng.rand }
    sel = [all.first] if sel.empty?
    mode = [:round, :sharp, :bevel][rng.rand(3)]
    opts = { :mode => mode, :offset => 0.2 + 0.8 * rng.rand, :segments => 1 + rng.rand(10) }
    begin
      e = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, opts)
      pr = M.check_closed(mesh, e)
      np = M.nonplanar(mesh, e)
      if pr.empty? && np.empty? then ok += 1 else fails["#{mode} closed=#{pr.size} np=#{np.size}"] += 1 end
    rescue SimpleCorners::Core::Error => ex
      if ex.message =~ /too large/ then big += 1 else fails[ex.message[0, 60]] += 1 end
    rescue => ex
      fails["CRASH #{ex.class}: #{ex.message[0, 80]} #{ex.backtrace[0]}"] += 1
    end
  end
end
puts "ok=#{ok} offset-too-large=#{big}"
fails.each { |k, v| puts "  #{v} x #{k}" }
