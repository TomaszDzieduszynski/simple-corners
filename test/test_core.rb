# Run with:  ruby test/test_core.rb
require 'minitest/autorun'
require_relative 'mesh_helpers'

class TestCore < Minitest::Test
  M = MeshHelpers
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
end
