# Stress test of the revert engine (Resharpen) on random solids:
#  1. round trip: the whole new surface reverted must give back the
#     original solid exactly, or be refused (Resharpen::Error).
#  2. random parts of the surface: the result must be a valid closed solid,
#     or be refused.
# Anything else (wrong result, crash, slow) is a bug.
# Usage: ruby test/dev/fuzz_revert.rb [rounds]   (default 300)
require_relative '../resharpen_helpers'

M = MeshHelpers
H = ResharpenHelpers
R = SimpleCorners::Resharpen
ROUNDS = (ARGV[0] || 300).to_i
SLOW = 5.0

def random_mesh(rng)
  $kind = nil
  k = rng.rand(12)
  $kind = %w[box lshape cylinder plate pyramid split_box slab star star stepped stepped_flush frustum][k]
  case k
  when 9 then M.stepped
  when 10 then M.stepped_flush(rng.rand < 0.5)
  when 11 then M.frustum(5 + rng.rand(12), 10, 2 + 7 * rng.rand, 5 + 20 * rng.rand, 10 * rng.rand - 5)
  when 0 then M.box(1 + 20 * rng.rand, 1 + 20 * rng.rand, 1 + 20 * rng.rand)
  when 1 then M.lshape
  when 2 then M.cylinder(3 + rng.rand(40), 1 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 3 then M.plate_with_hole
  when 4 then M.pyramid(2 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 5 then M.split_box
  when 6 then M.box(10, 10, 0.05 + 0.5 * rng.rand)
  else
    n = 3 + rng.rand(14)
    poly = (0...n).map do |i|
      a = 2 * Math::PI * (i + 0.45 * rng.rand) / n
      r = rng.rand < 0.2 ? 6 + 0.001 * rng.rand : 2 + 10 * rng.rand
      [r * Math.cos(a), r * Math.sin(a)]
    end
    M.prism(poly, 0.05 + 10 * rng.rand)
  end
end

def random_radius(rng)
  case rng.rand(5)
  when 0 then 10**(-3 + 2 * rng.rand)
  when 1 then 5 + 20 * rng.rand
  else 0.05 + 3 * rng.rand
  end
end

def size_of(mesh)
  (0..2).map { |i| mesh.points.map { |p| p[i] }.max - mesh.points.map { |p| p[i] }.min }.max
end

bugs = Hash.new { |h, k| h[k] = [] }
refused = Hash.new { |h, k| h[k] = [] }
stats = Hash.new(0)
rng = Random.new((ENV['SEED'] || 1).to_i)
ROUNDS.times do |it|
  mesh = random_mesh(rng)
  all = M.edges(mesh)
  sel = rng.rand < 0.4 ? all : all.select { rng.rand < 0.5 }
  sel = [all[rng.rand(all.size)]] if sel.empty?
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  opts = { :mode => mode, :offset => random_radius(rng), :segments => 1 + rng.rand(rng.rand < 0.2 ? 24 : 8) }
  tri = rng.rand < 0.2
  desc = "round #{it} #{$kind} #{opts} edges=#{sel.size}/#{all.size} tri=#{tri}"
  if ENV['DUMP'] && ENV['DUMP'].to_i == it
    File.binwrite(ENV['DUMP_TO'] || 'case.bin', Marshal.dump([mesh.points, mesh.faces, sel, opts, tri]))
  end
  begin
    pts, faces, region, = H.rounded(mesh, sel, opts, tri)
  rescue SimpleCorners::Core::Error
    stats[:engine_refused] += 1
    next
  end
  next if region.empty?
  stats[:cases] += 1
  t0 = Time.now
  begin
    polys = H.revert(pts, faces, region)
    diffs = H.compare(mesh, polys)
    if diffs.empty?
      stats[:exact] += 1
    else
      bugs["wrong result: #{diffs.first}"] << desc
    end
  rescue R::Error => e
    stats[:refused] += 1
    refused[e.message] << desc
  rescue StandardError, SystemStackError => e
    bugs["#{e.class}: #{e.message[0, 90]} @ #{e.backtrace[0]}"] << desc
  end
  dt = Time.now - t0
  stats[:max_s] = dt if dt > stats[:max_s]
  bugs['slow'] << "#{desc} #{dt.round(1)}s" if dt > SLOW

  # 2. a random part of the surface: valid or refused
  part = region.select { rng.rand < 0.5 }
  next if part.empty? || part.size == region.size
  begin
    polys = H.revert(pts, faces, part)
    tol = 1e-6 * (1 + size_of(mesh))
    probs = H.closed_problems(polys, tol)
    if probs.empty?
      stats[:part_ok] += 1
    else
      bugs["part: invalid result: #{probs.first}"] << desc
    end
  rescue R::Error
    stats[:part_refused] += 1
  rescue StandardError, SystemStackError => e
    bugs["part: #{e.class}: #{e.message[0, 90]} @ #{e.backtrace[0]}"] << desc
  end
end

puts "stats: #{stats.map { |k, v| "#{k}=#{v.is_a?(Float) ? v.round(2) : v}" }.join(' ')}"
puts 'refused (full surface):'
refused.sort_by { |_m, l| -l.size }.each { |m, l| puts "  #{l.size} x #{m}\n      e.g. #{l.first}" }
if bugs.empty?
  puts 'no bugs'
else
  bugs.each { |m, l| puts "#{l.size} x #{m}\n    e.g. #{l.first(3).join("\n         ")}" }
  exit 1
end
