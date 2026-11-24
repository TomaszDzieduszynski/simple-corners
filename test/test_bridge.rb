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

  # A delayed preview update (slow preview, quick mouse) must not replace a
  # newer one: radius 1, then 2 (delayed), then back to 1 (shown at once).
  def test_delayed_preview_does_not_bring_back_an_older_radius
    model.selection.add(build(M.box))
    tool = new_tool(:bevel)
    tool.send(:refresh_preview, 1.0)
    one = tool.instance_variable_get(:@preview)[:hard].map(&:to_a)
    slow = lambda do
      tool.instance_variable_set(:@last_cost, 1.0)
      tool.instance_variable_set(:@last_at, Time.now.to_f)
    end
    slow.call
    n = UI.timers.size
    tool.send(:refresh_preview, 2.0) # delayed
    assert_equal n + 1, UI.timers.size
    tool.send(:refresh_preview, 1.0) # shown already
    UI.timers.last.call
    assert_equal one, tool.instance_variable_get(:@preview)[:hard].map(&:to_a)
    # the same after a radius computed at once while the update waits
    slow.call
    tool.send(:refresh_preview, 2.0) # delayed
    tool.instance_variable_set(:@last_at, Time.now.to_f - 10)
    tool.send(:refresh_preview, 1.5) # at once
    want = SimpleCorners.preview(model, :bevel, 1.5)[:hard].map(&:to_a)
    UI.timers.last.call
    assert_equal want, tool.instance_variable_get(:@preview)[:hard].map(&:to_a)
    # a delayed update with nothing newer still arrives
    slow.call
    tool.send(:refresh_preview, 2.0)
    UI.timers.last.call
    assert_equal SimpleCorners.preview(model, :bevel, 2.0)[:hard].map(&:to_a), tool.instance_variable_get(:@preview)[:hard].map(&:to_a)
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

  # Bug report (1.1.12): with several copied groups selected (e.g. sofa
  # cushions made with Move + Ctrl), only the first copy was rounded: the
  # copies share one definition and the rest were skipped as duplicates.
  def test_every_selected_group_copy_is_rounded
    g = model.entities.add_group
    build(M.box, g.entities)
    copies = [g, model.entities.add_group_copy(g), model.entities.add_group_copy(g)]
    copies.each { |c| model.selection.add(c) }
    one = SimpleCorners.preview(model, :round, 1.0)[:hard].size
    assert_operator one, :>, 0
    assert_equal 3, SimpleCorners.targets(model).size
    assert SimpleCorners.apply(:round, 1.0, true)
    copies.each do |c|
      assert closed?(c.entities)
      assert_operator c.entities.grep(Sketchup::Face).size, :>, 6
    end
    assert_equal 3, copies.map(&:definition).uniq.size
  end

  # An unselected copy keeps its sharp edges.
  def test_unselected_group_copy_stays_sharp
    g = model.entities.add_group
    build(M.box, g.entities)
    other = model.entities.add_group_copy(g)
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true)
    assert_operator g.entities.grep(Sketchup::Face).size, :>, 6
    assert_equal 6, other.entities.grep(Sketchup::Face).size
  end

  # Bug report (1.1.13): groups inside a selected group were ignored.
  # Outer group (no geometry of its own) > two boxes and a group holding a
  # third box.
  def test_nested_groups_are_rounded
    outer = model.entities.add_group
    a = outer.entities.add_group
    b = outer.entities.add_group
    mid = outer.entities.add_group
    c = mid.entities.add_group
    [a, b, c].each { |g| build(M.box, g.entities) }
    model.selection.add(outer)
    assert_equal 5, SimpleCorners.targets(model).size
    res = SimpleCorners.preview(model, :round, 1.0)
    assert_nil res[:error]
    single = model.entities.add_group
    build(M.box, single.entities)
    model.selection.clear
    model.selection.add(single)
    one = SimpleCorners.preview(model, :round, 1.0)[:hard].size
    assert_equal 3 * one, res[:hard].size
    model.selection.clear
    model.selection.add(outer)
    assert SimpleCorners.apply(:round, 1.0, true)
    [a, b, c].each do |g|
      assert closed?(g.entities)
      assert_operator g.entities.grep(Sketchup::Face).size, :>, 6
    end
    assert_equal 6, single.entities.grep(Sketchup::Face).size
  end

  # A group nested in a copied group: only the selected copy changes.
  def test_nested_group_in_copied_group
    outer = model.entities.add_group
    inner = outer.entities.add_group
    build(M.box, inner.entities)
    other = model.entities.add_group_copy(outer)
    model.selection.add(outer)
    assert SimpleCorners.apply(:bevel, 1.0, true)
    mine = outer.entities.grep(Sketchup::Group).first
    theirs = other.entities.grep(Sketchup::Group).first
    assert_operator mine.entities.grep(Sketchup::Face).size, :>, 6
    assert closed?(mine.entities)
    assert_equal 6, theirs.entities.grep(Sketchup::Face).size
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

  # Zoomed in close, some edge ends are behind the camera. SketchUp before
  # 2025 mirrors such points onto the screen, so they are not drawn.
  def test_end_dots_behind_the_camera_are_not_drawn
    model.selection.add(build(M.box))
    tool = new_tool(:round)
    eye = pt(5, 5, 5) # inside the 10" box, looking along +x
    target = pt(10, 5, 5)
    persp = true
    @view.define_singleton_method(:camera) { Sketchup::Camera.new(eye, target, persp) }
    dots = []
    @view.define_singleton_method(:draw_points) { |pts, *_a| dots.concat(pts) }
    tool.draw(@view)
    refute_empty dots
    assert(dots.all? { |q| q.x > 5 }, 'a dot behind the camera was drawn')
    assert_equal 4, dots.map { |q| [q.x.round(2), q.y.round, q.z.round] }.uniq.size
    persp = false # parallel projection: nothing to mirror, all are drawn
    dots.clear
    tool.draw(@view)
    assert_equal 8, dots.map { |q| [q.x.round(2), q.y.round, q.z.round] }.uniq.size
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
  # One facet of an unsmoothed fillet selected: the whole edge reverts.
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
    assert SimpleCorners::Unround.run, UI.messages.last
    assert_equal 6, faces.size
    assert closed?
    assert_in_delta 1000.0, volume, 1e-6
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

  # A whole rounded / mitred / bevelled box (12 strips and 8 corners) is
  # one surface: all of it goes back to the box, in one undo step.
  def test_whole_rounded_box_reverted
    [:round, :sharp, :bevel].each do |mode|
      setup
      build(M.box)
      model.selection.add(faces)
      assert SimpleCorners.apply(mode, 2.0)
      model.selection.clear
      model.selection.add(new_surface(BOX_PLANES))
      model.ops.clear
      assert SimpleCorners::Unround.run, "#{mode}: #{UI.messages.inspect}"
      assert_equal 6, faces.size, mode.to_s
      assert_equal 12, model.entities.grep(Sketchup::Edge).size, mode.to_s
      assert closed?
      assert_in_delta 1000.0, volume, 1e-6
      assert_equal [[:start, 'Revert to Sharp Edge'], [:commit]], model.ops
    end
  end

  # Several rounded edges selected together: one alone (a strip) and two
  # meeting at a corner (a small network).
  def test_several_separate_edges_reverted
    build(M.box)
    es = model.entities.grep(Sketchup::Edge).select do |e|
      ps = [e.start.position, e.end.position]
      ps.all? { |q| q.z == 10 && q.y == 0 } || ps.all? { |q| q.z == 0 && q.y == 10 } || ps.all? { |q| q.x == 10 && q.y == 10 }
    end
    assert_equal 3, es.size
    model.selection.add(es)
    assert SimpleCorners.apply(:round, 2.0)
    model.selection.clear
    model.selection.add(new_surface(BOX_PLANES))
    assert_equal 2, SimpleCorners::Unround.surfaces(model.selection.to_a).size
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 6, faces.size
    assert closed?
    assert_in_delta 1000.0, volume, 1e-6
  end

  # A surface that is not recognised stays; the others are reverted.
  def test_unrecognised_surface_stays
    build(M.box)
    e = model.entities.grep(Sketchup::Edge).find { |x| [x.start, x.end].all? { |v| v.position.z == 10 && v.position.y == 0 } }
    model.selection.add(e)
    assert SimpleCorners.apply(:round, 2.0)
    strip = new_surface(BOX_PLANES)
    bottom = faces.find { |f| f.vertices.all? { |v| v.position.z == 0 } }
    model.selection.clear
    model.selection.add(strip)
    model.selection.add(bottom)
    assert SimpleCorners::Unround.run
    assert_match(/1 of 2 surfaces reverted/, UI.messages.last)
    assert_equal 6, faces.size
    assert closed?
    assert_in_delta 1000.0, volume, 1e-6
  end

  # Nothing recognised: no change, nothing left open.
  def test_nothing_recognised
    build(M.box)
    model.selection.add(faces.find { |f| f.vertices.all? { |v| v.position.z == 0 } })
    refute SimpleCorners::Unround.run
    assert_match(/does not belong|not recognised/, UI.messages.last)
    assert_equal 6, faces.size
    assert_equal [:abort], model.ops.last
  end

  def test_lshape_all_edges_reverted
    build(M.lshape)
    model.selection.add(faces)
    assert SimpleCorners.apply(:round, 1.5)
    l_planes = [[[0, 0, 1], 10], [[0, 0, -1], 0], [[0, -1, 0], 0], [[1, 0, 0], 20], [[0, 1, 0], 8], [[1, 0, 0], 8], [[0, 1, 0], 20], [[-1, 0, 0], 0]]
    model.selection.clear
    model.selection.add(new_surface(l_planes))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 8, faces.size
    assert closed?
    assert_in_delta 20 * 20 * 10 - 12 * 12 * 10, volume, 1e-6
  end

  # A faceted cylinder with smoothed sides and a rounded top rim: the
  # facets meet the top again and their edges stay smooth.
  def test_cylinder_rim_reverted_sides_stay_smooth
    build(M.cylinder(12, 10, 10))
    vertical = lambda do
      model.entities.grep(Sketchup::Edge).select { |x| (x.start.position.z - x.end.position.z).abs > 1e-9 }
    end
    vertical.call.each { |x| x.soft = true; x.smooth = true }
    rim = model.entities.grep(Sketchup::Edge).select { |x| [x.start, x.end].all? { |v| v.position.z == 10 } }
    model.selection.add(rim)
    assert SimpleCorners.apply(:round, 2.0)
    model.selection.clear
    model.selection.add(tagged_faces)
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 14, faces.size
    assert closed?
    assert_equal 12, vertical.call.size
    assert(vertical.call.all? { |x| x.soft? && x.smooth? && (x.start.position.z - x.end.position.z).abs > 9.999 })
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

  # One facet of an unsmoothed fillet on the same prism: the edge reverts.
  def test_shallow_corner_facet_reverted
    build(M.cylinder(12, 10, 10))
    e = model.entities.grep(Sketchup::Edge).find { |x| [x.start, x.end].all? { |v| (v.position.x - 10).abs < 1e-9 && v.position.y.abs < 1e-9 } }
    model.selection.add(e)
    SimpleCorners::Settings.smooth = false
    assert SimpleCorners.apply(:round, 3.0)
    SimpleCorners::Settings.smooth = true
    strip = tagged_faces.sort_by { |f| Math.atan2(f.vertices[0].position.y, f.vertices[0].position.x) }
    model.selection.clear
    n = 14
    model.selection.add(strip[strip.size / 2])
    assert SimpleCorners::Unround.run, UI.messages.last
    assert_equal n, faces.size
    assert closed?
  end

  # --- part of a rounded network: the rest stays rounded ----------------

  # Box edges as point pairs.
  def box_edges
    m = M.box
    M.edges(m).map { |a, b| [m.points[a], m.points[b]] }
  end

  def seg_dist(p, a, b)
    v = M::V
    ab = v.sub(b, a)
    t = [[v.dot(v.sub(p, a), ab) / v.dot(ab, ab), 0.0].max, 1.0].min
    v.dist(p, v.add(a, v.mul(ab, t)))
  end

  # New faces nearest to the given box edges (what belongs to their
  # rounding).
  def faces_of(edges)
    all = box_edges
    tagged_faces.select do |f|
      c = M::V.avg(f.vertices.map { |x| x.position.to_a })
      best = all.min_by { |a, b| seg_dist(c, a, b) }
      edges.include?(best)
    end
  end

  # What a click selects: faces connected by soft edges.
  def click(face)
    seen = { face => true }
    todo = [face]
    until todo.empty?
      f = todo.pop
      f.edges.each { |e| e.faces.each { |g| (seen[g] = true; todo << g) if e.soft? && !seen[g] } }
    end
    seen.keys
  end

  def box_rounded(mode, edges, r = 2.0)
    setup
    build(M.box)
    sel = model.entities.grep(Sketchup::Edge).select do |e|
      edges.any? { |a, b| [a, b].sort == [e.start.position.to_a, e.end.position.to_a].sort }
    end
    model.selection.add(sel)
    assert SimpleCorners.apply(mode, r)
    model.selection.clear
    [faces.size, volume]
  end

  TOP_FRONT = [[0.0, 0.0, 10.0], [10.0, 0.0, 10.0]].freeze

  # The bug report: on a mitred box, one fillet clicked and reverted. That
  # edge is sharp again, the other 11 stay as they were: the same as
  # rounding only those 11.
  def test_one_edge_of_a_network_reverted
    [:sharp, :round, :bevel].each do |mode|
      rest = box_edges.reject { |e| e.sort == TOP_FRONT.sort }
      want = box_rounded(mode, rest)
      box_rounded(mode, box_edges)
      strip = faces_of([box_edges.find { |e| e.sort == TOP_FRONT.sort }])
      refute_empty strip
      # a click on the fillet (round mode: one click selects the whole
      # smooth network, so its strip is selected face by face)
      model.selection.add(mode == :round ? strip : click(strip.max_by(&:area)))
      assert SimpleCorners::Unround.run, "#{mode}: #{UI.messages.inspect}"
      assert closed?, mode.to_s
      assert_equal want[0], faces.size, mode.to_s
      assert_in_delta want[1], volume, 1e-6, mode.to_s
      assert sharp_edge_restored?(0.0, 10.0), mode.to_s
    end
  end

  # The 4 top fillets of a mitred box reverted: the vertical and bottom
  # edges stay rounded (as if only those 8 were rounded).
  def test_top_ring_of_a_network_reverted
    [:sharp, :round, :bevel].each do |mode|
      top = box_edges.select { |a, b| a[2] == 10 && b[2] == 10 }
      want = box_rounded(mode, box_edges - top)
      box_rounded(mode, box_edges)
      model.selection.add(faces_of(top))
      assert SimpleCorners::Unround.run, "#{mode}: #{UI.messages.inspect}"
      assert closed?, mode.to_s
      assert_equal want[0], faces.size, mode.to_s
      assert_in_delta want[1], volume, 1e-6, mode.to_s
    end
  end

  # Mostly unselected edges stay rounded; an edge counts as selected when
  # at least half of its faces are.
  def test_majority_decides
    want = box_rounded(:sharp, box_edges.reject { |e| e.sort == TOP_FRONT.sort })
    box_rounded(:sharp, box_edges)
    strip = faces_of([box_edges.find { |e| e.sort == TOP_FRONT.sort }])
    model.selection.add(strip)
    model.selection.add(faces_of([box_edges.find { |a, b| a[2] == 0 && b[2] == 0 }]).first(1))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal want[0], faces.size
    assert_in_delta want[1], volume, 1e-6
  end

  # Builds a fixture (part of a real model) in the mock model; returns
  # [faces, fixture]. Faces with holes come first, so a face lying inside
  # a hole does not get in the way.
  def build_fixture(name)
    d = eval(File.read(File.expand_path("fixtures/#{name}.rb", __dir__)))
    ents = model.entities
    gp = lambda { |i| Geom::Point3d.new(*d[:points][i]) }
    out = []
    (0...d[:faces].size).sort_by { |i| -d[:faces][i][:loops].size }.each do |i|
      fd = d[:faces][i]
      f = ents.add_face(fd[:loops][0].map(&gp))
      f.inside = nil
      f.reverse! if f.normal.dot(Geom::Vector3d.new(*fd[:normal])) < 0
      fd[:loops][1..-1].each do |lp|
        h = ents.add_face(lp.map(&gp))
        h.inside = f
        h.erase!
      end
      out[i] = f
    end
    d[:soft].each do |a, b|
      e = ents.vertex_at(gp.call(a)).common_edge(ents.vertex_at(gp.call(b)))
      e.soft = e.smooth = true if e
    end
    [out, d]
  end

  def pt(x, y, z)
    Geom::Point3d.new(x, y, z)
  end

  def face_with_point?(x, y, z, size = nil)
    faces.any? do |f|
      (size.nil? || f.outer_loop.vertices.size == size) &&
        f.outer_loop.vertices.any? { |v| v.position.distance(pt(x, y, z)) < 1e-3 }
    end
  end

  def wall_face
    faces.select { |f| f.normal.x.abs > 0.999 && (f.vertices[0].position.x - 34.251969).abs < 1e-3 }.max_by(&:area)
  end

  # An arc drawn by hand in a doorway (tangent to the jamb only), ending
  # on a wall face that is divided right at the arc's end: a face left
  # inside the wall's door hole shares the hole's edge. The jamb and the
  # step are extended to a sharp edge; that face becomes a rectangle and
  # the wall keeps its holes.
  def test_revert_arc_ending_on_a_divided_wall
    fs, d = build_fixture('doorway')
    count = faces.size
    d[:faces].each_with_index { |fd, i| model.selection.add(fs[i]) if fd[:sel] }
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_empty UI.messages
    assert_equal count - 12, faces.size
    corner = [71.574803, 63.424743]
    assert face_with_point?(34.251969, *corner, 4), 'face in the door hole: now a rectangle'
    assert face_with_point?(24.803150, *corner, 4), 'step extended to the jamb'
    assert_equal 4, wall_face.loops.size, 'the wall keeps its holes'
    refute(faces.any? { |f| f.vertices.any? { |v| v.position.distance(pt(34.251969, 73.593647, 74.786535)) < 1e-3 } }, 'arc gone')
  end

  # Rounding an edge that ends on a face with holes, where another face
  # already lies inside the hole next to the edge: the hole must stay a
  # hole (SketchUp does not cut it by the usual add-and-erase).
  def test_round_keeps_hole_with_a_face_inside
    build_fixture('doorway')
    area = wall_face.area
    e = model.entities.grep(Sketchup::Edge).find do |x|
      ps = [x.start.position, x.end.position]
      ps.any? { |p| p.distance(pt(34.251969, 136.614173, 70.0)) < 1e-3 } && ps.any? { |p| p.distance(pt(24.803150, 136.614173, 90.5)) < 1e-3 }
    end
    model.selection.add(e)
    in_wall = lambda { faces.count { |f| f.normal.x.abs > 0.999 && (f.vertices[0].position.x - 34.251969).abs < 1e-3 } }
    before = in_wall.call
    assert SimpleCorners.apply(:round, 2.0), UI.messages.inspect
    w = wall_face
    assert_equal 4, w.loops.size, 'door hole kept'
    assert_equal before, in_wall.call, 'no new face in the wall plane: nothing covers the door'
    assert_operator w.area, :<, area + 1e-6
  end

  # The top of a ring of walls crossed by a partition: one outline that
  # runs out and back over the partition's edge (outer ring, edge, inner
  # ring backwards, edge back). SketchUp makes such faces but add_face
  # cannot take the outline back; it is built as a ring with a hole.
  def test_outline_through_a_point_twice_becomes_a_face_with_a_hole
    outer = [[0, 5], [0, 0], [10, 0], [10, 10], [0, 10], [0, 5]]
    inner = [[3, 5], [3, 7], [7, 7], [7, 3], [3, 3], [3, 5]]
    pts = (outer + inner).map { |x, y| pt(x, y, 0) }
    f = SimpleCorners::Bridge.add_face(model.entities, pts)
    refute_nil f
    assert_equal [5, 5], f.loops.map { |l| l.vertices.size }.sort # bridge ends stay on the rings
    assert(f.loops.reject(&:outer?).first.vertices.all? { |v| (3..7).cover?(v.position.x) && (3..7).cover?(v.position.y) }, "inner ring is the hole")
    assert_equal 1, faces.size
  end

  # A ring whose outline is joined to its hole by an out-and-back
  # diagonal edge. A point inside the outer square (the middle of a corner
  # triangle) lies in the hole, so nesting is decided on the outlines.
  def test_thin_ring_with_a_connector_becomes_a_face_with_a_hole
    ring = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0], [1, 1], [1, 9], [9, 9], [9, 1], [1, 1]]
    f = SimpleCorners::Bridge.add_face(model.entities, ring.map { |x, y| pt(x, y, 0) })
    refute_nil f
    assert_equal [4, 4], f.loops.map { |l| l.vertices.size }.sort
    assert(f.loops.reject(&:outer?).first.vertices.all? { |v| (1..9).cover?(v.position.x) }, 'inner square is the hole')
    assert_equal 1, faces.size
  end

  # SketchUp refusing a hole: the face is not made (it would cover the
  # hole and leave open edges around it) and nothing is left behind.
  def test_refused_hole_makes_no_face
    sq = lambda { |a, b| [[a, a], [b, a], [b, b], [a, b]].map { |x, y| pt(x, y, 0) } }
    f = refuse_face(2) { SimpleCorners::Bridge.face_with_holes(model.entities, [sq.call(0, 10), sq.call(3, 7)]) }
    assert_nil f
    assert_empty model.entities.to_a
    refute_nil SimpleCorners::Bridge.face_with_holes(model.entities, [sq.call(0, 10), sq.call(3, 7)])
  end

  # A group with a loose flat face (nothing to round) and a nested solid:
  # the nested solid is still rounded.
  def test_group_level_with_nothing_to_round_is_passed_over
    g = model.entities.add_group
    g.entities.add_face([pt(20, 0, 0), pt(30, 0, 0), pt(30, 10, 0), pt(20, 10, 0)])
    c = g.entities.add_group
    M.box.then { |m| m.faces.each { |f| c.entities.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*m.points[i]) }) } }
    model.selection.add(g)
    assert SimpleCorners.apply(:round, 1.0, true), UI.messages.inspect
    assert(c.entities.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 })
    assert_operator c.entities.grep(Sketchup::Face).size, :>, 6
    assert_equal 1, g.entities.grep(Sketchup::Face).size
  end

  # Nothing to round anywhere in a selected group: still an error.
  def test_group_with_nothing_to_round_is_refused
    g = model.entities.add_group
    g.entities.add_face([pt(0, 0, 0), pt(10, 0, 0), pt(10, 10, 0), pt(0, 10, 0)])
    model.selection.add(g)
    refute SimpleCorners.apply(:round, 1.0, true)
  end

  # --- 1.2.4: review fixes -------------------------------------------

  def box_in(ents, m = M.box)
    m.faces.each { |f| ents.add_face(f[:loops][0].map { |i| Geom::Point3d.new(*m.points[i]) }) }
  end

  # Placement scaled by sx, sy, sz (negative: mirrored), then moved by t.
  def placed(sx, sy, sz, t = [0, 0, 0], w = 1.0)
    Geom::Transformation.new([sx.to_f, 0, 0, 0, 0, sy.to_f, 0, 0, 0, 0, sz.to_f, 0, t[0].to_f, t[1].to_f, t[2].to_f, w])
  end

  # The face lying in the plane axis = value (local coordinates).
  def face_at(ents, axis, value)
    ents.grep(Sketchup::Face).find { |f| f.vertices.all? { |v| (v.position.to_a[axis] - value).abs < 1e-6 } }
  end

  def span(f, axis)
    xs = f.vertices.map { |v| v.position.to_a[axis] }
    [xs.min.round(6), xs.max.round(6)]
  end

  # Closed, and every face facing away from the middle of the 10" box.
  def sound_box?(ents)
    return false unless ents.grep(Sketchup::Edge).all? { |e| e.faces.size == 2 }
    ents.grep(Sketchup::Face).all? do |f|
      c = M::V.avg(f.vertices.map { |v| v.position.to_a })
      M::V.dot(f.normal.to_a, M::V.sub(c, [5, 5, 5])) > 0
    end
  end

  # Bevel of 1" (model) on a 10" box in a group whose local inch is
  # (kx, ky, kz) inches in the model: the faces are cut back 1/k locally.
  def assert_bevel_in_model_units(ents, kx, ky, kz)
    assert sound_box?(ents)
    top = face_at(ents, 2, 10)
    assert_equal [1.0 / kx, 10 - 1.0 / kx].map { |x| x.round(6) }, span(top, 0)
    assert_equal [1.0 / ky, 10 - 1.0 / ky].map { |x| x.round(6) }, span(top, 1)
    front = face_at(ents, 1, 0)
    assert_equal [1.0 / kz, 10 - 1.0 / kz].map { |x| x.round(6) }, span(front, 2)
  end

  def faces_tagged(ents)
    ents.grep(Sketchup::Face).select { |f| f.get_attribute('SimpleCorners', 'op') }
  end

  def top_front_edge
    model.entities.grep(Sketchup::Edge).find do |x|
      x.start.position.z == 10 && x.end.position.z == 10 && x.start.position.y == 0 && x.end.position.y == 0
    end
  end

  # Review (1.2.3): a group stretched along X got the average of its
  # scales (1.5" x 0.75" instead of 1"). The radius is now measured in the
  # model, and the preview shows the same.
  def test_stretched_group_is_bevelled_in_model_units
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(2, 1, 1, [100, 0, 0])
    model.selection.add(g)
    pv = SimpleCorners.preview(model, :bevel, 1.0)
    assert_nil pv[:error]
    refute_empty pv[:hard]
    pv[:hard].each do |p|
      assert_includes [100.0, 101.0, 119.0, 120.0], p.x.to_f.round(6), p.to_a.inspect
      assert_includes [0.0, 1.0, 9.0, 10.0], p.y.to_f.round(6), p.to_a.inspect
      assert_includes [0.0, 1.0, 9.0, 10.0], p.z.to_f.round(6), p.to_a.inspect
    end
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    assert_bevel_in_model_units(g.entities, 2, 1, 1)
    assert_equal [1.0], faces_tagged(g.entities).map { |f| f.get_attribute('SimpleCorners', 'radius') }.uniq
  end

  # The rounded vertical edge of a group stretched along X is a true
  # circle of 1" in the model (not an oval).
  def test_stretched_group_is_rounded_with_circles
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(2, 1, 1)
    model.selection.add(g)
    assert SimpleCorners.apply(:round, 1.0, true), UI.messages.inspect
    assert sound_box?(g.entities)
    arc = g.entities.grep(Sketchup::Face).flat_map(&:vertices).uniq.map { |v| v.position.to_a }
    # the end profile of the vertical strip, where the corner patch starts
    arc = arc.select { |x, y, z| (z - 9).abs < 1e-6 && 2 * x <= 1 + 1e-9 && y <= 1 + 1e-9 }
    assert_equal 7, arc.size
    arc.each { |x, y, _z| assert_in_delta 1.0, Math.hypot(2 * x - 1, y - 1), 1e-6, [x, y].inspect }
  end

  def test_mirrored_stretched_group_is_bevelled_in_model_units
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(-2, 1, 1, [100, 0, 0])
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    assert_bevel_in_model_units(g.entities, 2, 1, 1)
  end

  # Scales of nested groups multiply: (1, 2, 1) holding (2, 1, 1).
  def test_nested_scaled_groups_are_bevelled_in_model_units
    outer = model.entities.add_group
    outer.transformation = placed(1, 2, 1)
    inner = outer.entities.add_group
    inner.transformation = placed(2, 1, 1)
    box_in(inner.entities)
    model.selection.add(outer)
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    assert_bevel_in_model_units(inner.entities, 2, 2, 1)
  end

  # SketchUp before 2018 can keep a uniform scale in the last element.
  def test_uniform_scale_kept_in_the_last_element
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(1, 1, 1, [0, 0, 0], 0.5)
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    assert_bevel_in_model_units(g.entities, 2, 2, 2)
  end

  def test_space_only_for_scaled_placements
    sp = SimpleCorners::Bridge::Space
    assert_nil sp.for(Geom::Transformation.new)
    assert_nil sp.for(placed(-1, 1, 1, [5, 6, 7]))
    c = Math.cos(0.3)
    s = Math.sin(0.3)
    assert_nil sp.for(Geom::Transformation.new([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1.0, 0, 1, 2, 3, 1.0]))
    st = sp.for(Geom::Transformation.new([2 * c, 2 * s, 0, 0, -s, c, 0, 0, 0, 0, 1.0, 0, 1, 2, 3, 1.0]))
    refute_nil st
    q = st.to_local(st.to_model([1.5, -2.0, 3.25]))
    [1.5, -2.0, 3.25].each_with_index { |x, i| assert_in_delta x, q[i], 1e-12 }
    n = st.normal([0, 0, 1])
    [0, 0, 1].each_with_index { |x, i| assert_in_delta x, n[i], 1e-12 }
  end

  # Review (1.2.3): with a group holding only a flat face selected first,
  # nothing was rounded; with the box group first, it was.
  def test_selection_order_does_not_matter
    counts = [true, false].map do |flat_first|
      setup
      flat = model.entities.add_group
      flat.entities.add_face([[20, 0, 0], [30, 0, 0], [30, 10, 0], [20, 10, 0]].map { |x| Geom::Point3d.new(*x) })
      solid = model.entities.add_group
      box_in(solid.entities)
      (flat_first ? [flat, solid] : [solid, flat]).each { |x| model.selection.add(x) }
      assert SimpleCorners.apply(:round, 1.0, true), "flat first: #{flat_first} #{UI.messages.inspect}"
      assert sound_box?(solid.entities)
      assert_equal 1, flat.entities.grep(Sketchup::Face).size
      solid.entities.grep(Sketchup::Face).size
    end
    assert_equal counts[0], counts[1]
  end

  # Loose edges that cannot be rounded do not stop a selected group.
  def test_loose_flat_face_with_a_group_selected
    f = model.entities.add_face([[20, 0, 0], [30, 0, 0], [30, 10, 0], [20, 10, 0]].map { |x| Geom::Point3d.new(*x) })
    solid = model.entities.add_group
    box_in(solid.entities)
    model.selection.add(f)
    model.selection.add(solid)
    assert SimpleCorners.apply(:round, 1.0, true), UI.messages.inspect
    assert sound_box?(solid.entities)
  end

  # Review (1.2.3): the trimmed face came back visible and without the
  # data other extensions keep on it. It keeps both now (through Revert
  # too); the new faces of the rounding get neither.
  def test_trimmed_face_keeps_hidden_flag_and_attributes
    build(M.box)
    top = face_at(model.entities, 2, 10)
    top.hidden = true
    top.set_attribute('Customer', 'part_id', 1234)
    top.attribute_dictionary('Customer', true).attribute_dictionary('Sub', true)['k'] = 'v'
    model.selection.add(top_front_edge)
    assert SimpleCorners.apply(:round, 2.0)
    check = lambda do |tag|
      f = face_at(model.entities, 2, 10)
      assert f.hidden?, tag
      assert_equal 1234, f.get_attribute('Customer', 'part_id'), tag
      assert_equal 'v', f.attribute_dictionary('Customer').attribute_dictionary('Sub')['k'], tag
    end
    check.call('rounded')
    refute_empty faces_tagged(model.entities)
    faces_tagged(model.entities).each do |f|
      refute f.hidden?
      assert_nil f.get_attribute('Customer', 'part_id')
    end
    model.selection.clear
    model.selection.add(new_surface(BOX_PLANES))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 6, faces.size
    check.call('reverted')
    assert_equal 5, faces.count { |f| !f.hidden? }
  end

  # Review (1.2.3): SketchUp failing to explode the group of new faces
  # (it returns false) was taken as success with no faces.
  def test_failed_explode_aborts_round_and_revert
    build(M.box)
    model.selection.add(top_front_edge)
    Sketchup::Group.fail_explode = true
    begin
      refute SimpleCorners.apply(:round, 2.0)
      assert_equal [:abort], model.ops.last
      assert_match(/could not place the new faces/, UI.messages.join(' '))
    ensure
      Sketchup::Group.fail_explode = false
    end
    setup
    build(M.box)
    model.selection.add(top_front_edge)
    assert SimpleCorners.apply(:round, 2.0)
    model.selection.clear
    model.selection.add(new_surface(BOX_PLANES))
    Sketchup::Group.fail_explode = true
    begin
      refute SimpleCorners::Unround.run
      assert_equal [:abort], model.ops.last
      assert_match(/could not place the new faces/, UI.messages.join(' '))
    ensure
      Sketchup::Group.fail_explode = false
    end
  end

  # --- 1.2.4: second review ---------------------------------------------

  def strip_with_normal(ents, n)
    ents.grep(Sketchup::Face).find { |f| M::V.dist(f.normal.to_a, n) < 1e-6 }
  end

  # Review 2 (1.2.4): bevelled at 0.5x (1" in the model = 2" in the
  # group), then the group set back to 1x: reverting one bevel re-made the
  # others with the stored 1" instead of the 2" they have now.
  def test_partial_revert_after_the_group_was_scaled
    s2 = Math.sqrt(0.5)
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(0.5, 0.5, 0.5)
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    bottom = strip_with_normal(g.entities, [0, -s2, -s2])
    assert_equal [0.0, 2.0], span(bottom, 1)
    g.transformation = Geom::Transformation.new
    model.open_for_test([g])
    model.selection.clear
    model.selection.add(strip_with_normal(g.entities, [0, -s2, s2]))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    bottom = strip_with_normal(g.entities, [0, -s2, -s2])
    assert_equal [0.0, 2.0], span(bottom, 1), 'untouched bevel keeps its size'
    assert_equal [0.0, 2.0], span(bottom, 2)
    assert_nil strip_with_normal(g.entities, [0, -s2, s2]), 'the reverted bevel is gone'
  end

  # The scale is stored with the radius; same scale at revert: stored
  # radius still used.
  def test_radius_scale_stored_and_compared
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(2, 1, 1)
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true)
    mt = faces_tagged(g.entities).map { |f| f.get_attribute('SimpleCorners', 'metric') }.uniq
    assert_equal [[4.0, 0.0, 0.0, 1.0, 0.0, 1.0]], mt
    br = SimpleCorners::Bridge
    assert br.same_metric?(br.metric(placed(-2, 1, 1, [9, 9, 9])), mt[0]), 'moving and mirroring do not count'
    refute br.same_metric?(br.metric(nil), mt[0])
    model.open_for_test([g], placed(2, 1, 1))
    assert br.same_metric?(br.context_metric(model), mt[0])
  end

  # Review 2 (1.2.4): a valid tiny scale was taken for zero size, and the
  # preview raised an exception.
  def test_tiny_scale_is_not_zero_size
    g = model.entities.add_group
    box_in(g.entities, M.box(1e7, 1e7, 1e7))
    g.transformation = placed(1e-6, 1e-6, 1e-6)
    model.selection.add(g)
    pv = SimpleCorners.preview(model, :bevel, 1.0)
    assert_nil pv[:error]
    refute_empty pv[:hard]
    assert SimpleCorners.apply(:bevel, 1.0, true), Sketchup.status.inspect
    top = face_at(g.entities, 2, 1e7)
    assert_equal [1e6, 9e6], span(top, 0)
  end

  # A group flattened to zero size: a clean message, also in the preview.
  def test_zero_scale_is_reported_cleanly
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(1, 1, 0)
    model.selection.add(g)
    pv = SimpleCorners.preview(model, :bevel, 1.0)
    assert_match(/zero size/, pv[:error].to_s)
    refute SimpleCorners.apply(:bevel, 1.0, true)
    assert_equal [:abort], model.ops.last
  end

  # Review 2 (1.2.4): a small scaled group far from the origin lost
  # precision in the engine and its bevel failed.
  def test_scaled_group_far_from_the_origin
    [0.0, 20_000_000.9].each do |d|
      setup
      g = model.entities.add_group
      box_in(g.entities, M.box(0.125, 0.125, 0.125))
      g.transformation = placed(2, 2, 2, [d, d, d])
      model.selection.add(g)
      pv = SimpleCorners.preview(model, :bevel, 0.025)
      assert_nil pv[:error], "at #{d}"
      assert(pv[:hard].all? { |p| (p.x - d).abs <= 0.25 + 1e-6 }, "preview at #{d} drawn on the group")
      assert SimpleCorners.apply(:bevel, 0.025, true), "at #{d}: #{Sketchup.status.last}"
      top = face_at(g.entities, 2, 0.125)
      assert_equal [0.0125, 0.1125], span(top, 0), "at #{d}"
    end
  end

  # Review 3 (1.2.4): bevelled while stretched 2x along X, X set back to
  # 1x: the other bevels are no longer the same on both sides and cannot be
  # made again as they are. Partial revert is refused (model unchanged);
  # reverting the whole surface still works.
  def test_partial_revert_refused_after_an_uneven_stretch
    s2 = Math.sqrt(0.5)
    g = model.entities.add_group
    box_in(g.entities)
    g.transformation = placed(2, 1, 1)
    model.selection.add(g)
    assert SimpleCorners.apply(:bevel, 1.0, true), UI.messages.inspect
    g.transformation = Geom::Transformation.new
    model.open_for_test([g])
    before = g.entities.grep(Sketchup::Face).map { |f| f.vertices.map { |v| v.position.to_a } }.sort
    model.selection.clear
    model.selection.add(strip_with_normal(g.entities, [0, -s2, s2]))
    refute SimpleCorners::Unround.run
    assert_match(/stretched unevenly/, UI.messages.join(' '))
    assert_equal [:abort], model.ops.last
    assert_equal before, g.entities.grep(Sketchup::Face).map { |f| f.vertices.map { |v| v.position.to_a } }.sort
    UI.messages.clear
    model.selection.clear
    model.selection.add(faces_tagged(g.entities))
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 6, g.entities.grep(Sketchup::Face).size
  end

  def test_uniform_change
    br = SimpleCorners::Bridge
    assert br.uniform_change?(br.metric(placed(0.5, 0.5, 0.5)), br.metric(nil))
    assert br.uniform_change?(br.metric(placed(2, 1, 1)), br.metric(placed(-4, 2, 2, [5, 5, 5])))
    refute br.uniform_change?(br.metric(placed(2, 1, 1)), br.metric(nil))
  end

  # Review 3 (1.2.4): a flat-face group selected with a box group made the
  # preview say "No edge can be processed" (applying worked).
  def test_preview_of_a_mixed_selection
    [true, false].each do |flat_first|
      setup
      flat = model.entities.add_group
      flat.entities.add_face([[20, 0, 0], [30, 0, 0], [30, 10, 0], [20, 10, 0]].map { |x| Geom::Point3d.new(*x) })
      solid = model.entities.add_group
      box_in(solid.entities)
      (flat_first ? [flat, solid] : [solid, flat]).each { |x| model.selection.add(x) }
      pv = SimpleCorners.preview(model, :bevel, 1.0)
      assert_nil pv[:error], "flat first #{flat_first}"
      refute_empty pv[:hard]
    end
    setup
    flat = model.entities.add_group
    flat.entities.add_face([[20, 0, 0], [30, 0, 0], [30, 10, 0], [20, 10, 0]].map { |x| Geom::Point3d.new(*x) })
    model.selection.add(flat)
    assert_match(/No edge can be processed/, SimpleCorners.preview(model, :bevel, 1.0)[:error].to_s)
  end

  # Locked groups are left alone, as SketchUp's own tools do (its Ruby API
  # would let the edit through).
  def test_locked_group_is_left_alone
    g = model.entities.add_group
    box_in(g.entities)
    g.locked = true
    model.selection.add(g)
    pv = SimpleCorners.preview(model, :bevel, 1.0)
    assert_equal SimpleCorners::Bridge::LOCKED, pv[:error]
    assert_empty pv[:hard]
    refute SimpleCorners.apply(:bevel, 1.0)
    assert_match(/locked/, UI.messages.last.to_s)
    assert_equal 6, g.entities.grep(Sketchup::Face).size
  end

  def test_locked_child_of_a_group_is_left_alone
    parent = model.entities.add_group
    box_in(parent.entities)
    child = parent.entities.add_group
    box_in(child.entities)
    child.transformation = placed(1, 1, 1, [50, 0, 0])
    child.locked = true
    model.selection.add(parent)
    pv = SimpleCorners.preview(model, :bevel, 1.0)
    assert_nil pv[:error]
    refute_empty pv[:hard]
    assert pv[:hard].all? { |q| q.x < 20 }, 'no outline on the locked child'
    assert SimpleCorners.apply(:bevel, 1.0, true)
    assert_operator parent.entities.grep(Sketchup::Face).size, :>, 6
    assert_equal 6, child.entities.grep(Sketchup::Face).size
    assert(Sketchup.status.any? { |m| m.to_s.include?(SimpleCorners::Bridge::LOCKED_SKIPPED) })
  end

  def test_locked_and_unlocked_selected_together
    a = model.entities.add_group
    box_in(a.entities)
    b = model.entities.add_group
    box_in(b.entities)
    b.transformation = placed(1, 1, 1, [50, 0, 0])
    b.locked = true
    [b, a].each { |x| model.selection.add(x) }
    assert SimpleCorners.apply(:bevel, 1.0, true)
    assert_operator a.entities.grep(Sketchup::Face).size, :>, 6
    assert_equal 6, b.entities.grep(Sketchup::Face).size
  end

  # The preview runs the engine once per fit step (it used to repeat the
  # successful check run).
  module CountRuns
    class << self
      attr_accessor :runs
    end
    def run
      CountRuns.runs += 1 if CountRuns.runs
      super
    end
  end
  SimpleCorners::Core::Engine.prepend(CountRuns)

  def test_preview_runs_the_engine_once
    model.selection.add(build(M.box))
    CountRuns.runs = 0
    pv = SimpleCorners.preview(model, :round, 1.0)
    runs = CountRuns.runs
    CountRuns.runs = nil
    refute_empty pv[:hard]
    assert_equal 1, runs
  end

  # The drawing budget holds inside one large group too; the edge count
  # stays complete.
  def test_selection_drawing_budget_in_one_large_group
    g = model.entities.add_group
    n = 12_000
    g.entities.add_face((0...n).map { |k| t = 2 * Math::PI * k / n; Geom::Point3d.new(100 * Math.cos(t), 100 * Math.sin(t), 0) })
    model.selection.add(g)
    d = SimpleCorners.selection_data(model)
    assert_equal n, d[:edges]
    assert_operator d[:sel].size, :<=, 20_000
    assert_operator d[:sel].size, :>=, 19_998
  end

  def test_most_common_stored_value
    u = SimpleCorners::Unround
    assert_equal 2, u.most_common([2, 1, 1, 2])
    assert_equal 1, u.most_common([2, 1, 1])
    assert_equal true, u.most_common([true, false, true])
    assert_in_delta 0.5, u.most_common([0.5] * 5000 + [0.25] * 4999), 0
  end

  # Everything in the model, by position (faces and edges with their faces).
  def snapshot
    ents = model.entities
    key = lambda { |p| p.to_a.map { |x| x.round(6) } }
    fs = ents.grep(Sketchup::Face).map { |f| f.vertices.map { |v| key.call(v.position) }.sort }.sort
    es = ents.grep(Sketchup::Edge).map { |e| [[key.call(e.start.position), key.call(e.end.position)].sort, e.faces.size] }.sort
    [fs, es, ents.to_a.reject { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }.size]
  end

  # SketchUp refusing the n-th face (add_face returns nil).
  def refuse_face(n)
    calls = 0
    orig = SimpleCorners::Bridge.method(:add_face)
    SimpleCorners::Bridge.define_singleton_method(:add_face) do |es, pts|
      calls += 1
      calls == n ? nil : orig.call(es, pts)
    end
    yield
  ensure
    SimpleCorners::Bridge.define_singleton_method(:add_face) { |es, pts| orig.call(es, pts) }
  end

  # A refused face leaves the model as it was, without relying on the
  # operation being rolled back (SketchUp 2017 did not always do that; the
  # mock never does).
  def test_refused_face_leaves_the_model_untouched_when_rounding
    build(M.box)
    model.selection.add(model.entities.grep(Sketchup::Edge).find { |e| e.start.position.z == 10 && e.end.position.z == 10 })
    before = snapshot
    [1, 3, 6].each do |n|
      refuse_face(n) { refute SimpleCorners.apply(:round, 2.0) }
      assert_equal before, snapshot, "face #{n} refused"
    end
    assert SimpleCorners.apply(:round, 2.0), 'and it still works afterwards'
    assert closed?
  end

  def test_refused_face_leaves_the_model_untouched_when_reverting
    build(M.box)
    model.selection.add(model.entities.grep(Sketchup::Edge).find { |e| e.start.position.z == 10 && e.end.position.z == 10 })
    assert SimpleCorners.apply(:round, 2.0)
    tagged = faces.select { |f| f.get_attribute('SimpleCorners', 'op') }
    before = snapshot
    [1, 2].each do |n|
      model.selection.clear
      model.selection.add(tagged)
      refuse_face(n) { refute SimpleCorners::Unround.run }
      assert_equal before, snapshot, "face #{n} refused"
    end
    model.selection.clear
    model.selection.add(tagged)
    assert SimpleCorners::Unround.run, UI.messages.inspect
    assert_equal 6, faces.size
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
