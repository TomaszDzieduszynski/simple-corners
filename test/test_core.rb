# Run with:  ruby test/test_core.rb
require 'minitest/autorun'
require_relative 'mesh_helpers'

class TestCore < Minitest::Test
  M = MeshHelpers
  V = M::V
  MODES = [:round, :sharp, :bevel].freeze

  def run_ok(mesh, sel, opts)
    eng = M.run(mesh, sel, opts)
    probs = M.check_closed(mesh, eng)
    assert_empty probs, "mesh not closed (#{opts.inspect}): #{probs.first(5).inspect}"
    assert_empty M.nonplanar(mesh, eng), "non-planar polygons (#{opts.inspect})"
    eng
  end

  def top(m, z)
    M.edges_where(m) { |a, b| a[2] == z && b[2] == z }
  end

  def test_box_all_edges_all_modes
    MODES.each do |mode|
      [1, 2, 3, 6, 9].each do |segs|
        run_ok(M.box, M.edges(M.box), :mode => mode, :offset => 2.0, :segments => segs)
      end
    end
  end

  def test_round_box_volume_converges_to_exact_value
    d = 2.0
    s = 10.0
    exact = s**3 - 12 * (s - 2 * d) * d * d * (1 - Math::PI / 4) - 8 * (d**3 - Math::PI * d**3 / 6)
    eng = run_ok(M.box, M.edges(M.box), :mode => :round, :offset => d, :segments => 32)
    assert_in_delta exact, M.volume(M.box, eng), 0.2
  end

  def test_bevel_box_volume_is_exact
    eng = run_ok(M.box, M.edges(M.box), :mode => :bevel, :offset => 2.0)
    # 1000 - 12 edge prisms (6 x 2) - 8 corners (5/6 * d^3)
    assert_in_delta 1000 - 144 - 8 * (5.0 / 6) * 8, M.volume(M.box, eng), 1e-6
  end

  def test_partial_selections
    sels = {
      'top' => lambda { |m| top(m, 10) },
      'one vertical' => lambda { |m| M.edges_where(m) { |a, b| a[0] == 0 && b[0] == 0 && a[1] == 0 && b[1] == 0 } },
      'corner' => lambda { |m| M.edges_where(m) { |a, b| [a, b].include?([0.0, 0.0, 10.0]) } },
      'two opposite' => lambda { |m| M.edges_where(m) { |a, b| (a[2] == 10 && b[2] == 10 && a[1] == b[1]) } }
    }
    MODES.each do |mode|
      sels.each_value do |fn|
        m = M.box
        run_ok(m, fn.call(m), :mode => mode, :offset => 2.0, :segments => 5)
      end
    end
  end

  def test_lshape_concave_and_convex
    MODES.each do |mode|
      m = M.lshape
      run_ok(m, M.edges(m), :mode => mode, :offset => 2.0, :segments => 6)
      run_ok(m, top(m, 10), :mode => mode, :offset => 2.0, :segments => 6)
      concave = M.edges_where(m) { |a, b| a[0] == 8 && b[0] == 8 && a[1] == 8 && b[1] == 8 }
      eng = run_ok(m, concave, :mode => mode, :offset => 2.0, :segments => 6)
      assert_operator M.volume(m, eng), :>, 20 * 20 * 10 - 12 * 12 * 10, 'concave rounding must add material'
    end
  end

  def test_pyramid_cylinder_hole_split
    MODES.each do |mode|
      run_ok(M.pyramid, M.edges(M.pyramid), :mode => mode, :offset => 1.0, :segments => 6)
      c = M.cylinder
      run_ok(c, top(c, 10), :mode => mode, :offset => 1.5, :segments => 6)
      run_ok(c, M.edges(c), :mode => mode, :offset => 0.5, :segments => 4)
      h = M.plate_with_hole
      run_ok(h, M.edges(h), :mode => mode, :offset => 1.0, :segments => 4)
      s = M.split_box
      run_ok(s, M.edges(s), :mode => mode, :offset => 2.0, :segments => 4)
      half = M.edges_where(s) { |a, b| [a, b].include?([5.0, 0.0, 10.0]) && [a, b].include?([0.0, 0.0, 10.0]) }
      run_ok(s, half, :mode => mode, :offset => 2.0, :segments => 4)
    end
  end

  def test_convex_solids_stay_inside
    [[M.box, 2.0], [M.pyramid, 1.5], [M.cylinder, 0.5]].each do |mesh, off|
      MODES.each do |mode|
        eng = run_ok(mesh, M.edges(mesh), :mode => mode, :offset => off, :segments => 6)
        eng.points.each do |p|
          mesh.faces.each do |f|
            o = mesh.points[f[:loops][0][0]]
            assert_operator M::V.dot(M::V.sub(p, o), f[:normal]), :<=, 1e-7
          end
        end
      end
    end
  end

  def test_soft_edges_round_vs_bevel
    eng = run_ok(M.box, M.edges(M.box), :mode => :round, :offset => 2.0, :segments => 6)
    refute_empty eng.soft
    eng = run_ok(M.box, M.edges(M.box), :mode => :bevel, :offset => 2.0)
    assert_empty eng.soft
  end

  def test_offset_too_large
    err = assert_raises(SimpleCorners::Core::OffsetError) do
      M.run(M.box, M.edges(M.box), :mode => :round, :offset => 6.0, :segments => 4)
    end
    assert_match(/does not fit/i, err.message)
    assert_equal 8, err.vertices.size
  end

  def fit(mesh, sel, opts)
    eng = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, opts)
    assert_empty M.check_closed(mesh, eng)
    assert_empty M.nonplanar(mesh, eng)
    eng
  end

  def test_fit_reduces_everywhere_when_needed
    MODES.each do |mode|
      eng = fit(M.box, M.edges(M.box), :mode => mode, :offset => 6.0, :segments => 4)
      assert_equal 12, eng.reduced.size
      assert eng.reduced.values.all? { |d| d < 5.0 }
    end
  end

  # Only edges at the corners of a short edge get a smaller radius, each
  # one radius along its whole length.
  def test_fit_reduces_only_where_needed
    mesh = M.prism([[0, 0], [20, 0], [20, 10], [1.5, 10], [0, 8.5]], 10)
    sel = M.edges_where(mesh) { |a, b| a[2] == 10 && b[2] == 10 }
    MODES.each do |mode|
      eng = fit(mesh, sel, :mode => mode, :offset => 3.0, :segments => 6)
      refute_empty eng.reduced
      if mode == :sharp
        # mitred: the edges of the mitred loop share one radius
        assert_equal 1, eng.reduced.values.map { |d| d.round(9) }.uniq.size
        next
      end
      eng.reduced.each_key do |k|
        assert(k.any? { |v| p = mesh.points[v]; p[0] < 2 && p[1] > 8 }, "unexpected reduction of #{k.map { |v| mesh.points[v] }.inspect}")
      end
      assert_operator eng.reduced.size, :<=, 3
    end
  end

  def test_fit_random_prisms_never_fail
    rng = Random.new(99)
    40.times do |iter|
      n = 3 + rng.rand(8)
      poly = (0...n).map do |i|
        ang = 2 * Math::PI * (i + 0.4 * rng.rand) / n
        r = 3 + 9 * rng.rand
        [r * Math.cos(ang), r * Math.sin(ang)]
      end
      mesh = M.prism(poly, 2 + 8 * rng.rand)
      opts = { :mode => MODES[iter % 3], :offset => 1.0 + 2 * rng.rand, :segments => 1 + rng.rand(6) }
      fit(mesh, M.edges(mesh), opts)
    end
  end

  def test_open_geometry_rejected
    m = M.box
    m.faces.pop # remove one face -> open box
    sel = M.edges_where(m) { |a, b| a[2] == 10 && b[2] == 10 }
    assert_raises(SimpleCorners::Core::Error) { M.run(m, sel, :mode => :round, :offset => 1.0, :segments => 4) }
  end

  # Box whose top face is split in two coplanar faces by the edge a-b.
  def split_top_box
    m = M.box
    m.points << [5.0, 0.0, 10.0] << [5.0, 10.0, 10.0]
    a = m.points.size - 2
    b = m.points.size - 1
    m.faces[0][:loops] = [[4, a, b, 7]]
    m.faces << M.face([[a, 5, 6, b]], m.points)
    m.faces[2][:loops] = [[0, 1, 5, a, 4]]
    m.faces[4][:loops] = [[2, 3, 7, b, 6]]
    [m, a, b]
  end

  def test_coplanar_edges_ignored
    m, a, b = split_top_box
    assert_empty M.check_closed(m, Struct.new(:face_loops, :new_polys).new({}, []))
    assert_raises(SimpleCorners::Core::Error) { M.run(m, [[a, b]], :mode => :round, :offset => 1.0) }
    # Rounding the whole split top rim (front edge in two pieces) still works.
    sel = M.edges_where(m) { |p, q| p[2] == 10 && q[2] == 10 }
    MODES.each { |mode| run_ok(m, sel, :mode => mode, :offset => 1.0, :segments => 4) }
  end

  # Bug report: bevelling a wall face next to an earlier concave fillet left
  # "horns" (the original corner kept between the chamfers).
  def test_no_horns_next_to_fillet
    l = M.lshape
    concave = M.edges_where(l) { |a, b| a[0] == 8 && b[0] == 8 && a[1] == 8 && b[1] == 8 }
    e1 = M.run(l, concave, :mode => :round, :offset => 3.0, :segments => 6)
    polys = M.result_polys(l, e1)
    used = {}
    polys.each { |lps| lps.flatten.each { |i| used[i] = true } }
    map = {}
    pts = []
    used.keys.sort.each { |i| map[i] = pts.size; pts << e1.points[i] }
    faces = polys.map { |lps| M.face(lps.map { |lp| lp.map { |i| map[i] } }, pts) }
    m2 = M::Mesh.new(pts, faces)
    wall = faces.find do |f|
      f[:normal][1] > 0.99 && f[:loops][0].all? { |i| (pts[i][1] - 8).abs < 1e-9 } &&
        f[:loops][0].map { |i| pts[i][0] }.max > 19
    end
    lp = wall[:loops][0]
    sel = (0...lp.size).map { |i| [lp[i], lp[(i + 1) % lp.size]] }
    corners = lp.select { |i| (pts[i][0] - 11).abs < 1e-9 }
    MODES.each do |mode|
      eng = run_ok(m2, sel, :mode => mode, :offset => 0.5, :segments => 4)
      M.result_polys(m2, eng).each do |lps|
        corners.each { |cid| refute_includes lps.flatten, cid, "#{mode}: original corner kept (horn)" }
      end
    end
  end

  # Many segments: the radius search runs at fewer segments first; the
  # result must be the same kind of valid, reduced solid.
  def test_fit_with_many_segments
    [:round, :sharp].each do |mode|
      mesh = M.box
      eng = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, M.edges(mesh),
                                            :mode => mode, :offset => 7.0, :segments => 12)
      assert_equal 12, eng.reduced.size, mode
      assert_empty M.check_closed(mesh, eng), mode
      assert_empty M.nonplanar(mesh, eng), mode
    end
  end

  # Bug report: a block with a smaller block on its end. The end face is a
  # narrow frame: the outer fillets and the fillets at the joint overlap in
  # it, and the frame (and the window hole of the smaller block) turned
  # inside out, leaving a loose plate. Now the radius is reduced there.
  def test_overlapping_fillets_on_frame_faces
    [M.stepped, M.stepped_flush].each do |mesh|
      [1.5, 2.5, 4.0].each do |r|
        MODES.each do |mode|
          eng = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, M.edges(mesh),
                                                :mode => mode, :offset => r, :segments => 4)
          assert_empty M.check_closed(mesh, eng), "#{mode} r=#{r}"
          assert_empty M.hole_problems(mesh, eng), "#{mode} r=#{r}"
          refute_empty eng.reduced, "#{mode} r=#{r}: expected reduced corners"
        end
      end
    end
  end

  # Bug report: mitred mode on concave edges. A post on a block, its
  # vertical edges and foot edges rounded: at the foot corners the coves and
  # the post's rounded edge meet in a smooth blend, outlined by hard edges
  # (the user's choice).
  def test_mitred_post_foot
    mesh = M.stepped([[0, 0], [20, 0], [20, 20], [0, 20]], [[6, 6], [14, 6], [14, 14], [6, 14]], 14, 30)
    post = lambda { |p| p[0].between?(6, 14) && p[1].between?(6, 14) && p[2] >= 14 }
    sel = M.edges_where(mesh) { |a, b| post.call(a) && post.call(b) && !(a[2] == 44 && b[2] == 44) }
    sharp = run_ok(mesh, sel, :mode => :sharp, :offset => 1.0, :segments => 6)
    round = run_ok(mesh, sel, :mode => :round, :offset => 1.0, :segments => 6)
    [sharp, round].each { |e| assert_includes e.new_polys.map { |q| q[:kind] }, :patch_cusp }
    rim = lambda do |e|
      ids = e.new_polys.select { |q| q[:kind] == :patch_cusp }.map { |q| q[:ids] }
      count = Hash.new(0)
      ids.each { |lp| lp.each_with_index { |a, i| b = lp[(i + 1) % lp.size]; count[a < b ? [a, b] : [b, a]] += 1 } }
      count.select { |_k, n| n == 1 }.keys
    end
    assert rim.call(sharp).none? { |k| sharp.soft[k] }, 'mitred: blend outline must be hard'
    assert rim.call(round).all? { |k| round.soft[k] }, 'round: blend outline stays smooth'
  end

  # Bug report: mitred coves broke when the radius had to shrink on some
  # of them (a narrow strip next to the post). In mitred mode coves meeting
  # at a corner share one radius, so the mitres still match.
  def test_mitred_post_near_edge_shrinks_coves_together
    mesh = M.stepped([[0, 0], [24, 0], [24, 20], [0, 20]], [[3, 6], [11, 6], [11, 14], [3, 14]], 10, 30)
    post = lambda { |p| p[0].between?(3, 11) && p[1].between?(6, 14) && p[2] >= 10 }
    foot = M.edges_where(mesh) { |a, b| a[2] == 10 && b[2] == 10 && post.call(a) && post.call(b) }
    vert = M.edges_where(mesh) { |a, b| a[0] == b[0] && a[1] == b[1] && post.call(a) && post.call(b) && [a[0], a[1]] != [3, 14] }
    top = M.edges_where(mesh) { |a, b| a[2] == 10 && b[2] == 10 && !(post.call(a) && post.call(b)) }
    eng = fit(mesh, foot + vert + top, :mode => :sharp, :offset => 2.0, :segments => 6)
    radii = foot.map { |a, b| eng.reduced[[a, b].sort] || 2.0 }.uniq
    assert_equal 1, radii.size, "coves around the post differ: #{radii.inspect}"
  end

  # Bug report: trapezoids. When the radius does not fit next to a narrow
  # frame, the edges there get a smaller radius along their whole length;
  # the other edges keep the full radius.
  def test_reduced_edges_do_not_taper
    sofa = M.stepped([[0, 0], [20, 0], [20, 16], [0, 16]], [[1, 11], [18.5, 11], [18.5, 15.3], [1, 15.3]], 6, 9)
    eng = SimpleCorners::Core::Engine.fit(sofa.points, sofa.faces, M.edges(sofa), :mode => :round, :offset => 2.0, :segments => 6)
    assert_empty M.check_closed(sofa, eng)
    refute_empty eng.reduced
    # the front edges of the seat are not in the tight spots
    front = M.edges_where(sofa) { |a, b| a[1] == 0 && b[1] == 0 }.map(&:sort)
    front.each { |k| refute eng.reduced.key?(k), "front edge reduced: #{k.map { |v| sofa.points[v] }}" }
    # every edge has one offset: its fillet is as wide at both ends
    prof = eng.instance_variable_get(:@end_prof)
    eng.reduced.each_key do |k|
      a, b = k.map { |v| sofa.points[v] }
      dir = M::V.norm(M::V.sub(b, a))
      dist = lambda { |p| w = M::V.sub(p, a); M::V.len(M::V.sub(w, M::V.mul(dir, M::V.dot(w, dir)))) }
      widths = k.map { |v| ids = prof[[k, v]][0]; [dist.call(eng.points[ids[0]]), dist.call(eng.points[ids[-1]])].max }
      assert_in_delta widths[0], widths[1], 1e-6, "tapered edge #{[a, b].inspect}"
    end
  end

  # Random star-shaped prisms with random edge subsets.
  def test_random_prisms
    rng = Random.new(1234)
    60.times do |iter|
      n = 3 + rng.rand(7)
      poly = (0...n).map do |i|
        ang = 2 * Math::PI * (i + 0.3 * rng.rand) / n
        r = 6 + 6 * rng.rand
        [r * Math.cos(ang), r * Math.sin(ang)]
      end
      mesh = M.prism(poly, 4 + 6 * rng.rand)
      all = M.edges(mesh)
      sel = all.select { rng.rand < 0.6 }
      sel = [all.first] if sel.empty?
      mode = MODES[iter % 3]
      opts = { :mode => mode, :offset => 0.3 + 0.5 * rng.rand, :segments => 1 + rng.rand(8) }
      begin
        run_ok(mesh, sel, opts)
      rescue SimpleCorners::Core::OffsetError => e
        assert_match(/does not fit/i, e.message)
      end
    end
  end

  # An edge that runs into a wall at an angle (a block with a sloping top
  # against a wall): its end is the exact cut of the fillet by the wall, so
  # it lies flat on the wall, and the strip is made of flat quads.
  def test_slanted_edge_ends_flat_on_the_wall
    d = eval(File.read(File.expand_path('fixtures/slanted_edge.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces])
    sel = M.edges_where(mesh) { |a, b| (a[0] - 227.36).abs < 0.01 && (b[0] - 227.36).abs < 0.01 && a[1] != b[1] && a[2] != b[2] }
    assert_equal 1, sel.size
    wall = mesh.faces.index { |f| f[:normal][1] < -0.99 && f[:loops][0].size == 6 }
    { :round => 4, :sharp => 4, :bevel => 1 }.each do |mode, strips|
      eng = run_ok(mesh, sel, :mode => mode, :offset => 7.874, :segments => 4)
      assert_equal [:strip] * strips, eng.new_polys.map { |p| p[:kind] }, "#{mode}: flat strips only, no end patch"
      lp = eng.face_loops[wall][0]
      assert_equal 6 + strips, lp.size, "#{mode}: the wall follows the end of the fillet"
      # the wall's sharp corner is gone
      refute(lp.any? { |v| V.dist(eng.points[v], [227.362205, 0.0, 88.582677]) < 1e-3 }, mode.to_s)
      # both ends are the same curve (the fillet has one cross-section)
      next if mode == :bevel
      back = eng.points.select { |p| p[1].abs < 1e-9 && p[0] > 227.37 && p[0] < 235.2 }.map { |p| p[0] }.sort
      front = eng.points.select { |p| (p[1] + 37.795276).abs < 1e-6 && p[0] > 227.37 && p[0] < 235.2 }.map { |p| p[0] }.sort
      assert_equal 3, back.size
      back.zip(front).each { |a, b| assert_in_delta a, b, 1e-6 }
    end
  end

  # The same block, the edge on its other side: there the block's side is
  # one face with the side of the wall (a reflex corner where the edge
  # ends). The fillet runs on to the wall's plane and ends flat on it; it
  # must not be squared off inside the wall.
  def test_slanted_edge_on_a_shared_side_face_ends_on_the_wall
    d = eval(File.read(File.expand_path('fixtures/slanted_edge.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces])
    sel = M.edges_where(mesh) { |a, b| (a[0] - 278.74).abs < 0.01 && (b[0] - 278.74).abs < 0.01 && a[1] != b[1] && a[2] != b[2] }
    assert_equal 1, sel.size
    wall = mesh.faces.index { |f| f[:normal][1] < -0.99 && f[:loops][0].size == 6 }
    side = mesh.faces.index { |f| f[:normal][0] > 0.99 }
    { :round => 4, :sharp => 4, :bevel => 1 }.each do |mode, strips|
      eng = run_ok(mesh, sel, :mode => mode, :offset => 7.874, :segments => 4)
      assert_equal [:strip] * strips, eng.new_polys.map { |p| p[:kind] }, "#{mode}: flat strips only, no end patch"
      news = eng.points[mesh.points.size..-1]
      assert(news.all? { |p| p[1] < 1e-9 }, "#{mode}: nothing reaches into the wall")
      # the wall's front face comes down along its corner to the fillet's end
      low = [278.740157, 0.0, 88.59748 - 7.874 / 0.796508]
      [wall, side].each do |fi|
        assert(eng.face_loops[fi][0].any? { |v| V.dist(eng.points[v], low) < 1e-3 }, "#{mode}: face #{fi}")
      end
      assert_equal 6 + strips + 1, eng.face_loops[wall][0].size, mode.to_s
    end
  end

  # The same kind of block with both its sloping edge (convex, on the side
  # shared with the wall) and its edge along the wall (concave) selected:
  # the sloping fillet still runs on to the wall's plane, and nothing is
  # built behind the wall or beyond the side.
  def test_sloping_and_wall_edges_together_end_on_the_wall
    d = eval(File.read(File.expand_path('fixtures/sloped_block_shared_side.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces])
    top = [102.755906, 0.0, 88.59748]
    sel = M.edges_where(mesh) do |a, b|
      [a, b].any? { |p| V.dist(p, top) < 1e-3 } && [a, b].none? { |p| p[2] > 100 }
    end
    assert_equal 2, sel.size
    side = mesh.faces.index { |f| f[:normal][0] > 0.99 }
    [:round, :sharp, :bevel].each do |mode|
      eng = run_ok(mesh, sel, :mode => mode, :offset => 7.874, :segments => 4)
      news = eng.points[mesh.points.size..-1]
      assert(news.all? { |p| p[1] < 1e-6 }, "#{mode}: nothing behind the wall")
      assert(news.all? { |p| p[0] < 102.755906 + 1e-6 }, "#{mode}: nothing beyond the side")
      low = [102.755906, 0.0, 88.59748 - 7.874 / 0.796508]
      assert(eng.face_loops[side][0].any? { |v| V.dist(eng.points[v], low) < 1e-3 }, "#{mode}: side runs down the wall corner")
    end
  end

  # A box with a tilted top, its top edges selected: at each top corner the
  # vertical edge meets the two top edges at different angles, so their
  # offset lines cross it at different heights. Each fillet keeps its
  # radius along its whole length (nothing in a side face comes closer to
  # its top edge than the radius), and the corners are mitres, with one
  # fillet running on past the mitre where needed: no filler patches.
  def test_radius_constant_where_offset_lines_cross_an_edge_at_different_points
    [[10, 15], [10, 13], [13, 10]].each do |z1, z2|
      pts = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0], [0, 0, z1], [10, 0, z2], [10, 10, z2], [0, 10, z1]].map { |p| p.map(&:to_f) }
      faces = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]].map { |lp| M.face([lp], pts) }
      mesh = M::Mesh.new(pts, faces)
      sel = [[4, 5], [5, 6], [6, 7], [7, 4]]
      r = 1.0
      dist_line = lambda { |p, a, b| u = V.norm(V.sub(b, a)); w = V.sub(p, a); V.len(V.sub(w, V.mul(u, V.dot(w, u)))) }
      [:round, :sharp, :bevel].each do |mode|
        eng = run_ok(mesh, sel, :mode => mode, :offset => r, :segments => 4)
        assert_empty eng.reduced, "#{mode} #{z1}/#{z2}"
        assert_equal [:strip], eng.new_polys.map { |p| p[:kind] }.uniq, "#{mode} #{z1}/#{z2}: no filler patches"
        (2..5).each do |fi|
          top = sel.find { |a, b| faces[fi][:loops][0].include?(a) && faces[fi][:loops][0].include?(b) }
          eng.face_loops[fi][0].select { |v| v >= pts.size }.each do |v|
            dd = dist_line.call(eng.points[v], pts[top[0]], pts[top[1]])
            assert_operator dd, :>=, r - 1e-9, "#{mode} #{z1}/#{z2}: side face #{fi} tapers"
          end
        end
      end
    end
  end

  # A steep sill (78 degrees) in a door opening, all four edges selected:
  # its side edges meet the jambs' vertical corners at about 12 degrees, so
  # a fillet's offset line would meet those corners about 4.9 radii away.
  # No fillet may run on that far (a spike along the corner): every new
  # outline point stays within 1.5 radii of a selected edge.
  def test_steep_sill_makes_no_spikes
    d = eval(File.read(File.expand_path('fixtures/steep_sill.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces].map { |f| { :loops => f[:loops], :normal => f[:normal] } })
    lp = d[:faces].find { |f| f[:sel] }[:loops][0]
    sel = lp.each_index.map { |i| [lp[i], lp[(i + 1) % lp.size]] }
    r = 0.14173228
    seg = lambda do |p, a, b|
      ab = V.sub(b, a)
      t = [[V.dot(V.sub(p, a), ab) / V.dot(ab, ab), 0.0].max, 1.0].min
      V.dist(p, V.add(a, V.mul(ab, t)))
    end
    [:round, :sharp, :bevel].each do |mode|
      eng = M.run(mesh, sel, :mode => mode, :offset => r, :segments => 4)
      assert_empty M.nonplanar(mesh, eng), mode.to_s
      eng.face_loops.each_value do |loops|
        loops.flatten.uniq.select { |v| v >= mesh.points.size }.each do |v|
          far = sel.map { |a, b| seg.call(eng.points[v], mesh.points[a], mesh.points[b]) }.min
          assert_operator far, :<=, 1.5 * r, "#{mode}: spike at #{eng.points[v].map { |x| x.round(3) }}"
        end
      end
    end
  end

  # Mitred mode, corners where all three edges are selected: the corner's
  # polygons must not fold over each other (two neighbours about 180
  # degrees apart). Found by the corner fuzzer on a prism with a tilted top.
  def test_mitred_corner_does_not_fold
    d = eval(File.read(File.expand_path('fixtures/mitred_fold.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces])
    eng = run_ok(mesh, d[:sel], :mode => :sharp, :offset => d[:r], :segments => d[:segs])
    polys = M.result_polys(mesh, eng).flat_map { |loops| [loops[0]] }
    nrm = polys.map { |lp| V.norm(V.newell(lp.map { |k| eng.points[k] })) }
    owners = Hash.new { |h, k| h[k] = [] }
    polys.each_with_index { |lp, pi| lp.each_index { |i| owners[[lp[i], lp[(i + 1) % lp.size]].sort] << pi } }
    worst = owners.values.select { |l| l.size == 2 }.map do |a, b|
      Math.acos([[V.dot(nrm[a], nrm[b]), 1.0].min, -1.0].max) * 180 / Math::PI
    end.max
    assert_operator worst, :<, 170.0, 'polygons folded over each other'
  end

  # A fillet is one cross-section swept along its edge. Where one end runs
  # on past a mitre (its profile has more points), the strip used to join
  # mismatched points and twist: cut across, it showed two humps instead of
  # one arc. Every strip's mid section must stay on the fillet.
  def test_run_on_strips_keep_their_section
    d = eval(File.read(File.expand_path('fixtures/star_twist.rb', __dir__)))
    mesh = M::Mesh.new(d[:points], d[:faces])
    [:round, :sharp].each do |mode|
      [2, 3, 6, 12].each do |segs|
        eng = run_ok(mesh, d[:sel], :mode => mode, :offset => d[:r], :segments => segs)
        refute_empty eng.run_on_ids, 'the case must have run-on ends'
        worst, edge = M.section_depth(mesh, eng, d[:sel], d[:r], segs)
        assert_operator worst, :>, 0.98, "#{mode} #{segs} segments: strip of #{edge.inspect} twisted"
      end
    end
  end

  # Outlines above 600 points (two loops: 360,000 point pairs) used to skip
  # the crossing checks; now a grid finds what the pairwise loops find.
  def test_crossing_checks_on_large_outlines
    eng = SimpleCorners::Core::Engine.allocate
    eng.instance_variable_set(:@scale, 10.0)
    circle = lambda { |n, r| (0...n).map { |k| t = 2 * Math::PI * k / n; [r * Math.cos(t), r * Math.sin(t)] } }
    [600, 601, 3000].each do |n|
      p = circle.call(n, 10)
      assert_nil eng.send(:self_crossing, p), "n=#{n}"
      p[n / 2] = [15.0, 0.3] # pulled across the circle
      hit = eng.send(:self_crossing, p)
      refute_nil hit, "n=#{n}"
      assert_equal eng.send(:grid_crossing, p, p, true), hit
    end
    big = circle.call(700, 10)
    hole = circle.call(700, 5)
    assert_nil eng.send(:loops_crossing, big, hole)
    hole[10] = [30.0, 3.0]
    refute_nil eng.send(:loops_crossing, big, hole)
  end

end
