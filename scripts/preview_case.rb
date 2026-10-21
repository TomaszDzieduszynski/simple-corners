# Runs the engine on a test solid and writes an OBJ for scripts/render_obj.py.
# Usage: ruby scripts/preview_case.rb MESH MODE OFFSET SEGMENTS OUT.obj [SELECTION]
#   MESH: Ruby expression using MeshHelpers as M, e.g. "M.box", "M.lshape",
#         "M.pyramid", "M.cylinder(24, 10, 10)", "M.plate_with_hole"
#   SELECTION: optional block body selecting edges, e.g.
#         "M.edges_where(m) { |a, b| a[2] == 10 && b[2] == 10 }"  (default: all)
# Example:
#   ruby scripts/preview_case.rb "M.box" round 2 8 /tmp/box.obj
#   python3 scripts/render_obj.py /tmp/box.png 28 -55 /tmp/box.obj
require_relative '../test/mesh_helpers'
M = MeshHelpers
mesh = eval(ARGV[0])
sel = ARGV[5] ? eval("lambda { |m| #{ARGV[5]} }").call(mesh) : M.edges(mesh)
eng = M.run(mesh, sel, :mode => ARGV[1].to_sym, :offset => ARGV[2].to_f, :segments => ARGV[3].to_i)
probs = M.check_closed(mesh, eng)
puts "closed: #{probs.empty?}  volume: #{M.volume(mesh, eng).round(3)}  new polygons: #{eng.new_polys.size}"
M.write_obj(ARGV[4], mesh, eng)
