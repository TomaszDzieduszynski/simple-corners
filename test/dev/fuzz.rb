# Crash hunt: random solids, selections, radii, segment counts and modes,
# for the engine directly and for the SketchUp-side code on the mock API
# (commands, tool events, typed input, revert).
# Expected errors (Core::Error, Bridge::Error, Unround::Error, shown to the
# user as a message) are fine. Anything else is a bug, as are NaN
# coordinates in the result and runs slower than SLOW seconds.
# Usage: ruby test/dev/fuzz.rb [rounds]   (default 300)
require_relative '../mock_sketchup'
require_relative '../mesh_helpers'
Sketchup.model = Sketchup::Model.new
load File.expand_path('../../src/simple_corners.rb', __dir__)

M = MeshHelpers
SC = SimpleCorners
ROUNDS = (ARGV[0] || 300).to_i
SLOW = 5.0
bugs = Hash.new { |h, k| h[k] = [] }
stats = Hash.new(0)

def random_mesh(rng)
  case rng.rand(12)
  when 9 then M.stepped
  when 10 then M.stepped_flush(rng.rand < 0.5)
  when 11 then M.frustum(5 + rng.rand(12), 10, 2 + 7 * rng.rand, 5 + 20 * rng.rand, 10 * rng.rand - 5)
  when 0 then M.box(1 + 20 * rng.rand, 1 + 20 * rng.rand, 1 + 20 * rng.rand)
  when 1 then M.lshape
  when 2 then M.cylinder(3 + rng.rand(60), 1 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 3 then M.plate_with_hole
  when 4 then M.pyramid(2 + 10 * rng.rand, 0.5 + 10 * rng.rand)
  when 5 then M.split_box
  when 6 # thin slab: radius usually far too large
    M.box(10, 10, 0.01 + 0.2 * rng.rand)
  else # random star-shaped prism, sometimes with tiny or near-collinear sides
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
  when 0 then 10**(-6 + 4 * rng.rand)  # tiny
  when 1 then 10 + 1e4 * rng.rand      # huge
  else 0.05 + 3 * rng.rand
  end
end

def bad_numbers?(eng)
  eng.points.any? { |p| p.any? { |c| !c.is_a?(Numeric) || c.nan? || c.infinite? } }
end

# 1. Engine.
rng = Random.new(1)
ROUNDS.times do |it|
  mesh = random_mesh(rng)
  all = M.edges(mesh)
  sel = rng.rand < 0.3 ? all : all.select { rng.rand < 0.5 }
  sel = [all[rng.rand(all.size)]] if sel.empty?
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  opts = { :mode => mode, :offset => random_radius(rng), :segments => 1 + rng.rand(rng.rand < 0.2 ? 64 : 12) }
  t0 = Time.now
  begin
    eng = SC::Core::Engine.fit(mesh.points, mesh.faces, sel, opts)
    bugs['engine: NaN/Infinity in result'] << "round #{it} #{opts}" if bad_numbers?(eng)
    stats[:engine_ok] += 1
  rescue SC::Core::Error
    stats[:engine_expected_error] += 1
  rescue StandardError, SystemStackError => e
    bugs["engine: #{e.class}: #{e.message[0, 90]} @ #{e.backtrace[0]}"] << "round #{it} #{opts}"
  end
  dt = Time.now - t0
  stats[:engine_max_s] = dt if dt > stats[:engine_max_s]
  bugs['engine: slow'] << "round #{it} #{dt.round(1)}s #{opts} edges=#{sel.size}" if dt > SLOW
end

# 2. SketchUp side on the mock API.
class FuzzView
  attr_accessor :line_width, :drawing_color, :line_stipple, :tooltip
  def initialize(rng, model)
    @rng = rng
    @model = model
  end
  def invalidate; end
  def draw(*_a); end
  def draw_points(*_a); end
  def draw2d(*_a); end
  def point_at(_x, _y)
    Geom::Point3d.new(20 * @rng.rand - 5, 20 * @rng.rand - 5, 20 * @rng.rand - 5)
  end
  def pick_helper
    ents = @model.active_entities.to_a
    rng = @rng
    o = Object.new
    o.define_singleton_method(:do_pick) { |*_a| nil }
    o.define_singleton_method(:best_picked) { rng.rand < 0.2 || ents.empty? ? nil : ents[rng.rand(ents.size)] }
    o
  end
end

TEXTS = ['8', '8s', '0', '-3', '1000s', '0s', 'abc', '', ' ', '5mm', '1e99', '1e-12', '2,5', '1/2"', '3\'', 'NaN', '64', '65'].freeze

def build(model, mesh)
  mesh.faces.each do |f|
    model.entities.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*mesh.points[i]) })
  end
end

def unexpected_messages
  UI.messages.select { |m| m.to_s =~ /failed/ }
end

rng = Random.new(2)
ROUNDS.times do |it|
  Sketchup.model = model = Sketchup::Model.new
  UI.messages.clear
  view = FuzzView.new(rng, model)
  model.define_singleton_method(:active_view) { view }
  SC::Settings.radius = random_radius(rng)
  SC::Settings.segments = 1 + rng.rand(12)
  build(model, random_mesh(rng))
  ents = model.entities.to_a
  ents.sample(1 + rng.rand(ents.size), random: rng).each { |e| model.selection.add(e) } if rng.rand < 0.7
  mode = [:round, :sharp, :bevel][rng.rand(3)]
  step = nil
  begin
    case rng.rand(4)
    when 0 # command with the last radius (context menu)
      step = 'apply'
      SC.apply(mode, SC::Settings.radius)
    when 1 # smooth/unsmooth selection
      step = 'smooth'
      SC.toggle_smooth_selection
    else # tool: random events
      tool = SC::CornerTool.new(mode)
      model.select_tool(tool)
      tool.activate
      (5 + rng.rand(25)).times do
        break unless model.tool_history.last.equal?(tool)
        x = rng.rand(100)
        y = rng.rand(100)
        case rng.rand(10)
        when 0..3 then step = 'move'; tool.onMouseMove(0, x, y, view)
        when 4, 5 then step = 'click'; tool.onLButtonDown(rng.rand < 0.2 ? 4 : 0, x, y, view)
        when 6 then step = 'release'; tool.onLButtonUp(0, x, y, view)
        when 7 then step = 'text'; tool.onUserText(TEXTS[rng.rand(TEXTS.size)], view)
        when 8 then step = 'esc'; tool.onCancel(0, view)
        else step = 'enter'; tool.onReturn(view)
        end
        step = 'draw'
        tool.draw(view)
      end
    end
    # Revert on whatever rounded surface exists now.
    tagged = model.entities.grep(Sketchup::Face).select { |f| f.get_attribute(SC::Bridge::DICT, 'op') }
    unless tagged.empty?
      step = 'unround'
      model.selection.clear
      model.selection.add(tagged.sample(1 + rng.rand(tagged.size), random: rng))
      SC::Unround.run
    end
    unexpected_messages.each { |m| bugs["ui message: #{m.to_s[0, 100]}"] << "round #{it} #{mode}" }
    bugs['operation left open'] << "round #{it}" if model.ops.last && model.ops.last[0] == :start
    stats[:ui_rounds] += 1
  rescue StandardError, SystemStackError => e
    bugs["ui (#{step}): #{e.class}: #{e.message[0, 90]} @ #{e.backtrace[0]}"] << "round #{it} #{mode}"
  end
end

puts "stats: #{stats.map { |k, v| "#{k}=#{v.is_a?(Float) ? v.round(2) : v}" }.join(' ')}"
if bugs.empty?
  puts 'no unexpected errors'
else
  bugs.each { |k, v| puts "#{v.size} x #{k}\n    e.g. #{v.first(2).join(' | ')}" }
end
