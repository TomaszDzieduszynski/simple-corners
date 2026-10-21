# Runs the SketchUp-side code (loader, bridge, tool) on the mock API.
# Run with:  ruby test/test_bridge.rb
require 'minitest/autorun'
require_relative 'mock_sketchup'
require_relative 'mesh_helpers'

Sketchup.model = Sketchup::Model.new
load File.expand_path('../src/simple_corners.rb', __dir__)

class TestBridge < Minitest::Test
  M = MeshHelpers

  # View stub: picking returns what the test sets, input points come from
  # a table of screen positions.
  class ViewStub
    attr_accessor :line_width, :drawing_color, :line_stipple, :tooltip
    attr_reader :lines, :styles

    def initialize
      @points = {}
      @lines = []
      @styles = []
    end

    def invalidate; end

    def draw(_mode, pts)
      @lines << pts
      @styles << [line_width, drawing_color]
    end

    def draw_points(*_a); end

    def at(x, y, point, picked = nil)
      @points[[x, y]] = [point, picked]
    end

    def point_at(x, y)
      (@points[[x, y]] || [Geom::Point3d.new(0, 0, 0)])[0]
    end

    def pick_helper
      view = self
      o = Object.new
      o.define_singleton_method(:do_pick) { |x, y| @xy = [x, y] }
      o.define_singleton_method(:best_picked) { (view.instance_variable_get(:@points)[@xy] || [])[1] }
      o
    end
  end

  def setup
    Sketchup.model = Sketchup::Model.new
    UI.messages.clear
    Sketchup.status.clear
    SimpleCorners::Settings.radius = 2.0
    SimpleCorners::Settings.segments = 6
    @view = ViewStub.new
    view = @view
    model.define_singleton_method(:active_view) { view }
  end

  def model
    Sketchup.active_model
  end

  def build(mesh, ents = model.entities)
    mesh.faces.map do |f|
      ents.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*mesh.points[i]) })
    end
  end

  def closed?(ents = model.entities)
    ents.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 }
  end

  def pt(x, y, z)
    Geom::Point3d.new(x, y, z)
  end

  def new_tool(mode)
    t = SimpleCorners::CornerTool.new(mode)
    model.select_tool(t)
    t.activate
    t
  end

  def test_click_edge_then_two_points
    build(M.box)
    edge = model.entities.grep(Sketchup::Edge).find { |e| e.start.position.z == 10 && e.end.position.z == 10 }
    tool = new_tool(:round)
    tool.onUserText('8', @view) # before the first click: segments
    assert_equal 8, SimpleCorners::Settings.segments
    @view.at(1, 1, pt(5, 0, 10), edge)
    @view.at(2, 2, pt(5, 0, 7.5))
    tool.onMouseMove(0, 1, 1, @view)
    tool.draw(@view)
    assert_match(/Click: round this edge/, @view.tooltip)
    tool.onLButtonDown(0, 1, 1, @view)         # picks the edge, point 1
    assert model.selection.include?(edge)
    tool.onMouseMove(0, 2, 2, @view)           # live preview with radius 2.5
    pv = tool.instance_variable_get(:@preview)
    refute_empty pv[:hard]
    assert_nil pv[:error]
    tool.draw(@view)
    tool.onLButtonDown(0, 2, 2, @view)         # point 2 -> apply
    assert closed?
    assert_equal [:commit], model.ops.last
    assert_in_delta 2.5, SimpleCorners::Settings.radius, 1e-9
    assert_nil model.tool_history.last, 'should return to the Select tool'
  end

  def test_preselection_typed_radius
    faces = build(M.box)
    model.selection.add(faces)
    tool = new_tool(:sharp)
    pv = tool.instance_variable_get(:@preview)
    assert_equal 6 * 2 * 3, pv[:tris].size # 6 quads as 2 triangles each
    refute_empty pv[:ends]
    @view.at(1, 1, pt(0, 0, 0))
    tool.onLButtonDown(0, 1, 1, @view)         # point 1 (selection kept)
    tool.onUserText('5mm', @view)              # after the first click: radius
    assert closed?
    assert_in_delta 5 / 25.4, SimpleCorners::Settings.radius, 1e-9
    assert_nil model.tool_history.last
  end

  def test_enter_uses_last_radius_and_bevel_typing
    faces = build(M.box)
    model.selection.add(faces)
    tool = new_tool(:bevel)
    tool.onUserText('1', @view)                # bevel: a number is the offset
    assert closed?
    assert_in_delta 1.0, SimpleCorners::Settings.radius, 1e-9
    setup
    faces = build(M.box)
    model.selection.add(faces)
    tool = new_tool(:round)
    tool.onReturn(@view)
    assert closed?
    assert_equal [:commit], model.ops.last
  end

  def test_click_drag_release
    build(M.box)
    edge = model.entities.grep(Sketchup::Edge).find { |e| e.start.position.z == 10 && e.end.position.z == 10 }
    tool = new_tool(:bevel)
    @view.at(1, 1, pt(5, 0, 10), edge)
    @view.at(40, 40, pt(5, 0, 8))
    tool.onLButtonDown(0, 1, 1, @view)
    tool.onLButtonUp(0, 40, 40, @view)
    assert closed?
    assert_in_delta 2.0, SimpleCorners::Settings.radius, 1e-9
  end

  def test_group_click
    g = model.entities.add_group
    build(M.box, g.entities)
    tool = new_tool(:round)
    @view.at(1, 1, pt(0, 0, 10), g)
    @view.at(2, 2, pt(0, 0, 8.5))
    tool.onLButtonDown(0, 1, 1, @view)
    assert model.selection.include?(g)
    tool.onMouseMove(0, 2, 2, @view)
    refute_empty tool.instance_variable_get(:@preview)[:hard]
    tool.onLButtonDown(0, 2, 2, @view)
    assert closed?(g.entities)
    assert_operator g.entities.grep(Sketchup::Face).size, :>, 6
  end

  # Bug report (SketchUp 2025): inside an open group everything was drawn
  # shifted by the group's placement. SketchUp reports world coordinates
  # in the open context, so nothing may be transformed again for drawing.
  def test_drawing_inside_open_group_is_not_shifted
    g = model.entities.add_group
    build(M.box, g.entities)
    ents = g.entities
    moved = Geom::Transformation.translation([100, 0, 0])
    model.define_singleton_method(:active_path) { [g] }
    model.define_singleton_method(:active_entities) { ents }
    model.define_singleton_method(:edit_transform) { moved }
    Sketchup.define_singleton_method(:version) { '25.0.660' }
    edge = ents.grep(Sketchup::Edge).first
    tool = new_tool(:round)
    @view.at(5, 5, pt(0, 0, 0), edge)
    tool.onMouseMove(0, 5, 5, @view)
    @view.lines.clear
    tool.draw(@view)
    drawn = @view.lines.flatten.map(&:to_a)
    ends = [edge.start.position.to_a, edge.end.position.to_a]
    ends.each { |e| assert_includes drawn, e }
  ensure
    Sketchup.define_singleton_method(:version) { '17.0.18899' }
  end

  def test_modifiers_and_escape
    faces = build(M.box)
    e1, e2 = faces[0].edges
    tool = new_tool(:round)
    @view.at(1, 1, pt(0, 0, 0), e1)
    @view.at(2, 2, pt(0, 0, 0), e2)
    tool.onLButtonDown(COPY_MODIFIER_MASK, 1, 1, @view)
    tool.onLButtonDown(COPY_MODIFIER_MASK, 2, 2, @view)
    assert_equal 2, model.selection.to_a.size
    tool.onLButtonDown(CONSTRAIN_MODIFIER_MASK, 1, 1, @view)
    assert_equal [e2], model.selection.to_a
    tool.onLButtonDown(0, 2, 2, @view)         # starts the radius
    assert_equal :radius, tool.instance_variable_get(:@state)
    tool.onCancel(0, @view)
    assert_equal :select, tool.instance_variable_get(:@state)
    refute model.selection.empty?
    tool.onCancel(0, @view)
    assert model.selection.empty?
    menu = UI::Menu.new
    assert tool.getMenu(menu, 0, 0, 0, @view)
  end

  # Bug report: "offset is too large" boxes. Now the radius is reduced only
  # where needed, with a notice instead of an error.
  def test_too_large_radius_is_reduced
    faces = build(M.box)
    model.selection.add(faces)
    tool = new_tool(:round)
    @view.at(1, 1, pt(0, 0, 0))
    @view.at(2, 2, pt(0, 0, 7))
    tool.onLButtonDown(0, 1, 1, @view)
    tool.onMouseMove(0, 2, 2, @view)
    pv = tool.instance_variable_get(:@preview)
    assert_nil pv[:error]
    assert_equal 12, pv[:reduced]
    tool.onLButtonDown(0, 2, 2, @view)
    assert_equal [:commit], model.ops.last
    assert closed?
    assert_empty UI.messages
    assert_match(/reduced on 12 edge/, Sketchup.status.last(5).join(' '))
    assert_nil model.tool_history.last
  end

  # Hover outline: thick for an edge, thin for a face.
  def test_hover_widths
    faces = build(M.box)
    edge = model.entities.grep(Sketchup::Edge).first
    tool = new_tool(:round)
    hover = SimpleCorners::CornerTool::HOVER_COLOR
    widths = lambda do |ent|
      @view.at(5, 5, pt(0, 0, 0), ent)
      tool.onMouseMove(0, 5, 5, @view)
      @view.styles.clear
      tool.draw(@view)
      @view.styles.select { |_w, c| c == hover }.map(&:first).uniq
    end
    assert_equal [SimpleCorners::CornerTool::HOVER_WIDTH], widths.call(edge)
    assert_equal [SimpleCorners::CornerTool::HOVER_FACE_WIDTH], widths.call(faces[0])
    assert_operator SimpleCorners::CornerTool::HOVER_FACE_WIDTH, :<, SimpleCorners::CornerTool::HOVER_WIDTH
  end

  # Tool drawing is moved a tiny step toward the camera, so lines lying on
  # faces are not hidden by them (new graphics engine of SketchUp 2025).
  def test_drawing_is_lifted_toward_camera
    faces = build(M.box)
    tool = new_tool(:round)
    eye = pt(30, -40, 50)
    cam = Sketchup::Camera.new(eye, pt(5, 5, 5))
    @view.define_singleton_method(:camera) { cam }
    @view.at(5, 5, pt(0, 0, 0), faces[0])
    tool.onMouseMove(0, 5, 5, @view)
    @view.lines.clear
    tool.draw(@view)
    drawn = @view.lines.flatten
    refute_empty drawn
    orig = faces[0].edges.flat_map { |e| [e.start.position, e.end.position] }
    drawn.first(2).each do |q|
      o = orig.min_by { |p| p.distance(q) }
      d = o.distance(eye)
      assert_operator q.distance(eye), :<, d, 'not moved toward the camera'
      assert_in_delta d * 0.001, o.distance(q), d * 1e-6
    end
  end

  # Very heavy jobs (here 64 segments on a whole box) ask first; "No"
  # leaves the model untouched.
  def test_heavy_job_asks_first
    model.selection.add(build(M.box))
    SimpleCorners::Settings.segments = 64
    UI.answer = IDNO
    refute SimpleCorners.apply(:round, 2.0)
    assert_match(/about \d+ faces/, UI.messages.last)
    assert_empty model.ops
    assert_equal 6, model.entities.grep(Sketchup::Face).size
  ensure
    UI.answer = IDYES
  end

  # The preview shows only the outline where the new surfaces will meet the
  # original faces: every line lies on a face of the box, 2 from its edges.
  def test_preview_draws_outline_only
    model.selection.add(build(M.box))
    SimpleCorners::Settings.segments = 64
    res = SimpleCorners.preview_result(model, :round, 2.0)
    assert_nil res[:error]
    assert_empty res[:soft]
    assert_equal 6 * 4 * 2, res[:hard].size # 4 lines on each of the 6 faces
    res[:hard].each do |q|
      c = q.to_a
      assert(c.any? { |x| x.abs < 1e-9 || (x - 10).abs < 1e-9 }, "not on a face: #{c.inspect}")
      assert(c.count { |x| (x - 2).abs < 1e-9 || (x - 8).abs < 1e-9 } >= 2, "not 2 from the edges: #{c.inspect}")
    end
  end

  # An unexpected error inside the engine must not break the tool.
  def test_preview_survives_engine_bug
    model.selection.add(build(M.box))
    SimpleCorners::Bridge.singleton_class.send(:alias_method, :orig_compute, :compute)
    SimpleCorners::Bridge.define_singleton_method(:compute) { |*_a| raise NoMethodError, 'simulated bug' }
    tool = new_tool(:round)
    @view.at(1, 1, pt(0, 0, 0))
    @view.at(2, 2, pt(0, 0, 1))
    tool.onLButtonDown(0, 1, 1, @view)
    tool.onMouseMove(0, 2, 2, @view)
    tool.draw(@view)
    assert_match(/not available/, tool.instance_variable_get(:@preview)[:error])
    tool.onLButtonDown(0, 2, 2, @view)
    assert_equal [:abort], model.ops.last
    assert_match(/failed: simulated bug/, UI.messages.last)
    assert_nil model.tool_history.last
  ensure
    SimpleCorners::Bridge.singleton_class.send(:alias_method, :compute, :orig_compute)
  end

  def test_failure_returns_to_select_tool
    faces = build(M.box)
    faces[1].erase! # open box: the corners cannot be processed
    model.selection.add(model.entities.grep(Sketchup::Edge))
    tool = new_tool(:round)
    @view.at(1, 1, pt(0, 0, 0))
    @view.at(2, 2, pt(0, 0, 1))
    tool.onLButtonDown(0, 1, 1, @view)
    tool.onLButtonDown(0, 2, 2, @view)
    assert_equal [:abort], model.ops.last
    assert_match(/open or non-manifold/, UI.messages.last)
    assert_nil model.tool_history.last
  end

  def test_smooth_setting_and_toggle
    build(M.box)
    model.selection.add(model.entities.grep(Sketchup::Face))
    SimpleCorners::Settings.smooth = false
    assert SimpleCorners.apply(:round, 2.0)
    soft_off = model.entities.grep(Sketchup::Edge).count(&:soft?)
    tagged = model.entities.grep(Sketchup::Face).select { |f| f.get_attribute('SimpleCorners', 'op') }
    refute_empty tagged
    setup
    build(M.box)
    model.selection.add(model.entities.grep(Sketchup::Face))
    SimpleCorners::Settings.smooth = true
    assert SimpleCorners.apply(:round, 2.0)
    soft_on = model.entities.grep(Sketchup::Edge).count(&:soft?)
    assert_operator soft_on, :>, soft_off
    # Toggle on the rounded surface: unsmooth, then smooth again.
    tagged = model.entities.grep(Sketchup::Face).select { |f| f.get_attribute('SimpleCorners', 'op') }
    model.selection.clear
    model.selection.add(tagged)
    assert SimpleCorners.toggle_smooth_selection
    inner = model.entities.grep(Sketchup::Edge).select { |e| e.faces.size == 2 && e.faces.all? { |f| tagged.include?(f) } }
    refute_empty inner
    assert inner.none?(&:soft?)
    assert SimpleCorners.toggle_smooth_selection
    assert inner.all?(&:soft?)
    SimpleCorners::Settings.smooth = true
  end

  def test_all_modes_on_shapes
    [[M.lshape, 2.0], [M.pyramid, 1.0]].each do |mesh, r|
      [:round, :sharp, :bevel].each do |mode|
        setup
        faces = build(mesh)
        model.selection.add(faces)
        assert SimpleCorners.apply(mode, r), "#{mode}: #{UI.messages.inspect}"
        assert closed?, "#{mode} not closed"
      end
    end
  end

  def test_partial_selection_keeps_other_edge_properties
    build(M.box)
    vertical = model.entities.grep(Sketchup::Edge).select { |e| (e.start.position.z - e.end.position.z).abs > 1 }
    vertical.each { |e| e.hidden = true }
    top = model.entities.grep(Sketchup::Edge).select { |e| e.start.position.z == 10 && e.end.position.z == 10 }
    model.selection.add(top)
    assert SimpleCorners.apply(:round, 2.0)
    assert closed?
    vert_now = model.entities.grep(Sketchup::Edge).select do |e|
      a = e.start.position
      b = e.end.position
      (a.x - b.x).abs < 1e-9 && (a.y - b.y).abs < 1e-9 && [0.0, 10.0].include?(a.x) && [0.0, 10.0].include?(a.y)
    end
    refute_empty vert_now
    assert vert_now.all?(&:hidden?)
  end
end

class TestUnround < Minitest::Test
  M = MeshHelpers

  def setup
    Sketchup.model = Sketchup::Model.new
    UI.messages.clear
    SimpleCorners::Settings.segments = 6
  end

  def model
    Sketchup.active_model
  end

  def build(mesh)
    mesh.faces.map { |f| model.entities.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*mesh.points[i]) }) }
  end

  def faces
    model.entities.grep(Sketchup::Face)
  end

  def closed?
    model.entities.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 }
  end

  def volume
    faces.inject(0.0) do |vol, f|
      p = f.vertices.map { |v| v.position.to_a }
      (1...p.size - 1).inject(vol) { |s, i| s + M::V.dot(p[0], M::V.cross(p[i], p[i + 1])) / 6.0 }
    end
  end

  # The rounded surface, found from the geometry (faces not lying on the
  # original box planes), as a user would select it by clicking.
  def new_surface(planes)
    faces.reject do |f|
      planes.any? { |n, d| (M::V.dot(f.normal.to_a, n) - 1).abs < 1e-9 && (M::V.dot(f.vertices[0].position.to_a, n) - d).abs < 1e-9 }
    end
  end

  BOX_PLANES = [[[0, 0, 1], 10], [[0, 0, -1], 0], [[1, 0, 0], 10], [[-1, 0, 0], 0], [[0, 1, 0], 10], [[0, -1, 0], 0]].freeze

  def test_revert_single_edge_all_modes
    [:round, :sharp, :bevel].each do |mode|
      setup
      build(M.box)
      e = model.entities.grep(Sketchup::Edge).find { |x| x.start.position.z == 10 && x.end.position.z == 10 && x.start.position.y == 0 && x.end.position.y == 0 }
      model.selection.add(e)
      assert SimpleCorners.apply(mode, 2.0)
      assert_operator faces.size, :>, 6
      model.selection.clear
      model.selection.add(new_surface(BOX_PLANES))
      assert SimpleCorners::Unround.run, UI.messages.inspect
      assert_equal 6, faces.size, mode.to_s
      assert_equal 12, model.entities.grep(Sketchup::Edge).size
      assert closed?
      assert_in_delta 1000.0, volume, 1e-6
    end
  end

  def test_revert_concave_fillet
    build(M.lshape)
    e = model.entities.grep(Sketchup::Edge).find { |x| [x.start, x.end].all? { |v| v.position.x == 8 && v.position.y == 8 } }
    model.selection.add(e)
    assert SimpleCorners.apply(:round, 2.0)
    l_planes = [[[0, 0, 1], 10], [[0, 0, -1], 0], [[0, -1, 0], 0], [[1, 0, 0], 20], [[0, 1, 0], 8], [[1, 0, 0], 8], [[0, 1, 0], 20], [[-1, 0, 0], 0]]
    model.selection.clear
    model.selection.add(new_surface(l_planes))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 8, faces.size
    assert closed?
    assert_in_delta 20 * 20 * 10 - 12 * 12 * 10, volume, 1e-6
  end

  # Part of a rounded surface (one segment): its neighbouring segments are
  # extended until they meet.
  def test_partial_selection_reverted
    build(M.box)
    e = model.entities.grep(Sketchup::Edge).find { |x| x.start.position.z == 10 && x.end.position.z == 10 && x.start.position.y == 0 && x.end.position.y == 0 }
    model.selection.add(e)
    SimpleCorners::Settings.smooth = false
    assert SimpleCorners.apply(:round, 2.0)
    SimpleCorners::Settings.smooth = true
    strip = new_surface(BOX_PLANES)
    model.selection.clear
    model.selection.add(strip[strip.size / 2]) # one segment only
    n = faces.size
    assert SimpleCorners::Unround.run, UI.messages.last
    assert_equal n - 1, faces.size
    assert closed?
  end

  # Faces of the strip along the top-front edge (y = 0, z = 10), between
  # its corners.
  def front_top_strip(d)
    faces.select do |f|
      ps = f.vertices.map { |v| v.position }
      ps.all? { |q| q.y < d + 1e-6 && q.z > 10 - d - 1e-6 && q.x > d - 1e-6 && q.x < 10 - d + 1e-6 } &&
        !ps.all? { |q| (q.z - 10).abs < 1e-9 } && !ps.all? { |q| q.y.abs < 1e-9 }
    end
  end

  def sharp_edge_restored?(y, z)
    model.entities.grep(Sketchup::Edge).any? do |e|
      [e.start, e.end].all? { |v| (v.position.y - y).abs < 1e-6 && (v.position.z - z).abs < 1e-6 }
    end
  end

  def test_revert_strip_between_other_bevels_and_fillets
    [:bevel, :round].each do |mode|
      setup
      build(M.box)
      model.selection.add(faces)
      assert SimpleCorners.apply(mode, 2.0)
      strip = front_top_strip(2.0)
      refute_empty strip
      model.selection.clear
      model.selection.add(strip)
      n_before = faces.size
      v_before = volume
      assert SimpleCorners::Unround.run, "#{mode}: #{UI.messages.inspect}"
      assert closed?, "#{mode}: not closed"
      assert sharp_edge_restored?(0.0, 10.0), "#{mode}: no sharp edge"
      assert_operator volume, :>, v_before
      assert_operator faces.size, :<, n_before + 3
    end
  end

  # The bug report case: a bevel along the top, ending at rounded vertical
  # edges.
  def test_revert_bevel_next_to_rounded_edges
    build(M.box)
    vert = model.entities.grep(Sketchup::Edge).select { |e| (e.start.position.z - e.end.position.z).abs > 1 }
    model.selection.add(vert)
    assert SimpleCorners.apply(:round, 2.0)
    top = faces.find { |f| f.normal.z > 0.99 && f.vertices.all? { |v| (v.position.z - 10).abs < 1e-9 } }
    model.selection.clear
    model.selection.add(top)
    assert SimpleCorners.apply(:bevel, 0.8)
    strip = faces.select do |f|
      ps = f.vertices.map(&:position)
      ps.all? { |q| q.y < 0.8 + 1e-6 && q.z > 9.2 - 1e-6 && q.x > 2 - 1e-6 && q.x < 8 + 1e-6 } && f.normal.z < 0.99 && f.normal.y > -0.99
    end
    assert_equal 1, strip.size
    model.selection.clear
    model.selection.add(strip)
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert closed?
    assert sharp_edge_restored?(0.0, 10.0)
  end

  def test_complex_surface_not_recognised
    build(M.box)
    model.selection.add(faces)
    assert SimpleCorners.apply(:round, 2.0)
    n = faces.size
    model.selection.clear
    model.selection.add(new_surface(BOX_PLANES)) # all 12 fillets + 8 corners
    refute SimpleCorners::Unround.run
    assert_match(/not recognised/, UI.messages.last)
    assert_equal n, faces.size
  end
  def tagged_faces
    faces.select { |f| f.get_attribute(SimpleCorners::Bridge::DICT, 'op') }
  end

  # Bug report: a bevel on a vertical edge of a many-sided prism (side faces
  # meeting at 30 degrees) was not recognised.
  def test_revert_bevel_on_shallow_corner
    build(M.cylinder(12, 10, 10))
    n = faces.size
    e = model.entities.grep(Sketchup::Edge).find { |x| [x.start, x.end].all? { |v| (v.position.x - 10).abs < 1e-9 && v.position.y.abs < 1e-9 } }
    model.selection.add(e)
    assert SimpleCorners.apply(:bevel, 0.5)
    model.selection.clear
    model.selection.add(tagged_faces)
    assert SimpleCorners::Unround.run, UI.messages.last
    assert_equal n, faces.size
    assert closed?
    assert(model.entities.grep(Sketchup::Edge).any? { |x| [x.start, x.end].all? { |v| (v.position.x - 10).abs < 1e-6 && v.position.y.abs < 1e-6 } })
  end

  # Bug reports: a bevel and a smoothed fillet on a side edge of a leaning,
  # tapered 10-sided prism (side faces meeting at 36 degrees).
  def test_revert_on_leaning_prism
    [[:bevel, 0.6], [:round, 0.8], [:sharp, 0.8]].each do |mode, r|
      setup
      build(M.frustum)
      n = faces.size
      e = model.entities.grep(Sketchup::Edge).find { |x| [x.start.position.z, x.end.position.z].sort == [0, 20] }
      ends = [e.start.position.to_a, e.end.position.to_a]
      model.selection.add(e)
      assert SimpleCorners.apply(mode, r)
      model.selection.clear
      model.selection.add(tagged_faces)
      assert SimpleCorners::Unround.run, "#{mode}: #{UI.messages.last}"
      assert_equal n, faces.size, mode
      assert closed?, mode
      restored = model.entities.grep(Sketchup::Edge).any? do |x|
        [x.start, x.end].all? { |v| ends.any? { |q| M::V.dist(v.position.to_a, q) < 1e-6 } }
      end
      assert restored, "#{mode}: sharp edge not restored"
    end
  end

  # One facet of an unsmoothed fillet on the same prism.
  def test_shallow_corner_facet_reverted
    build(M.cylinder(12, 10, 10))
    e = model.entities.grep(Sketchup::Edge).find { |x| [x.start, x.end].all? { |v| (v.position.x - 10).abs < 1e-9 && v.position.y.abs < 1e-9 } }
    model.selection.add(e)
    SimpleCorners::Settings.smooth = false
    assert SimpleCorners.apply(:round, 3.0)
    SimpleCorners::Settings.smooth = true
    strip = tagged_faces.sort_by { |f| Math.atan2(f.vertices[0].position.y, f.vertices[0].position.x) }
    model.selection.clear
    model.selection.add(strip[strip.size / 2])
    n = faces.size
    assert SimpleCorners::Unround.run, UI.messages.last
    assert_equal n - 1, faces.size
    assert closed?
  end

  def test_unexpected_error_is_reported
    build(M.box)
    model.selection.add(faces.first)
    SimpleCorners::Unround.singleton_class.send(:alias_method, :orig_analyse, :analyse)
    SimpleCorners::Unround.define_singleton_method(:analyse) { |*_a| raise TypeError, 'simulated bug' }
    refute SimpleCorners::Unround.run
    assert_match(/failed: simulated bug/, UI.messages.last)
    refute_equal :start, (model.ops.last || [])[0]
  ensure
    SimpleCorners::Unround.singleton_class.send(:alias_method, :analyse, :orig_analyse)
  end
end

class TestIcons < Minitest::Test
  def with_platform(version, platform)
    old_v = Sketchup.method(:version)
    Sketchup.define_singleton_method(:version) { version }
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, platform)
    yield
  ensure
    Sketchup.define_singleton_method(:version, old_v)
  end

  def test_icon_formats_by_version_and_platform
    real = RUBY_PLATFORM
    with_platform('17.0.1', 'x64-mingw32') { assert_match(/round\.svg\z/, SimpleCorners.icon(:round, 16)) }
    with_platform('24.0.1', 'x86_64-darwin') { assert_match(/round\.pdf\z/, SimpleCorners.icon(:round, 24)) }
    with_platform('15.3.1', 'x64-mingw32') { assert_match(/round_16\.png\z/, SimpleCorners.icon(:round, 16)) }
    with_platform('15.3.1', 'x64-mingw32') { assert_match(/cursor_bevel\.png\z/, SimpleCorners.icon('cursor_bevel')) }
    %w[round sharp bevel smooth_new smooth_sel unround cursor_round cursor_sharp cursor_bevel].each do |n|
      %w[svg pdf].each { |ext| assert File.exist?(File.join(SimpleCorners::PATH, 'icons', "#{n}.#{ext}")), "#{n}.#{ext}" }
    end
  ensure
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, real)
  end
end
