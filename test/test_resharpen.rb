# Tests of the revert engine (Resharpen): every case rounds, mitres or
# bevels a solid with the real engine, reverts the whole new surface and
# expects the original solid back (same corners, faces and volume).
# Run with:  ruby test/test_resharpen.rb
require 'minitest/autorun'
require_relative 'resharpen_helpers'

class TestResharpen < Minitest::Test
  M = MeshHelpers
  H = ResharpenHelpers
  R = SimpleCorners::Resharpen
  MODES = [:round, :sharp, :bevel].freeze

  def round_trip(mesh, sel, mode, r, seg = 6, triangulate = false)
    pts, faces, region, = H.rounded(mesh, sel, { :mode => mode, :offset => r, :segments => seg }, triangulate)
    refute_empty region
    polys = H.revert(pts, faces, region)
    H.compare(mesh, polys)
  end

  def assert_round_trip(mesh, sel, mode, r, seg = 6, triangulate = false, what = '')
    diffs = round_trip(mesh, sel, mode, r, seg, triangulate)
    assert_empty diffs, "#{what} #{mode} r=#{r} seg=#{seg}"
  rescue R::Error => e
    flunk "#{what} #{mode} r=#{r} seg=#{seg}: #{e.message}"
  end

  def test_box_all_edges
    MODES.each do |mode|
      [0.5, 2.0, 4.9].each { |r| assert_round_trip(M.box, M.edges(M.box), mode, r, 6, false, 'box') }
    end
  end

  def test_box_segments
    [1, 2, 3, 12].each { |seg| assert_round_trip(M.box, M.edges(M.box), :round, 2.0, seg, false, 'box') }
  end

  def test_box_edge_subsets
    m = M.box
    all = M.edges(m)
    top = M.edges_where(m) { |a, b| a[2] == 10 && b[2] == 10 }
    vert = M.edges_where(m) { |a, b| a[2] != b[2] }
    two = all.select { |a, b| [m.points[a], m.points[b]].all? { |q| q[1] == 0 } }
    [top, vert, top + vert, two, [all[0]], all[0, 3]].each do |sel|
      MODES.each { |mode| assert_round_trip(m, sel, mode, 2.0, 6, false, "box #{sel.size} edges") }
    end
  end

  # Corner patches and strips split into triangles (as other tools or
  # imports may leave them).
  def test_triangulated_surface
    MODES.each { |mode| assert_round_trip(M.box, M.edges(M.box), mode, 2.0, 6, true, 'triangulated box') }
  end

  def test_lshape_concave_and_convex
    m = M.lshape
    MODES.each do |mode|
      assert_round_trip(m, M.edges(m), mode, 1.5, 6, false, 'lshape')
      inner = M.edges_where(m) { |a, b| a[0] == 8 && b[0] == 8 && a[1] == 8 && b[1] == 8 }
      assert_round_trip(m, inner, mode, 1.5, 6, false, 'lshape inner edge')
      top = M.edges_where(m) { |a, b| a[2] == 10 && b[2] == 10 }
      assert_round_trip(m, top + inner, mode, 1.5, 6, false, 'lshape top + inner')
    end
  end

  def test_face_with_hole
    m = M.plate_with_hole
    MODES.each do |mode|
      assert_round_trip(m, M.edges(m), mode, 1.0, 6, false, 'plate with hole')
      rim = M.edges_where(m) { |a, b| a[2] == 6 && b[2] == 6 && [a, b].all? { |q| q[0].between?(10, 20) && q[1].between?(10, 20) } }
      assert_round_trip(m, rim, mode, 1.0, 6, false, 'hole rim')
    end
  end

  # Four faces meeting in one point.
  def test_pyramid_apex
    m = M.pyramid
    MODES.each { |mode| assert_round_trip(m, M.edges(m), mode, 1.0, 6, false, 'pyramid') }
  end

  # Faceted surfaces: the facets are extended until they meet again.
  def test_prisms_and_cylinders
    [M.cylinder(12, 10, 10), M.cylinder(5, 10, 4), M.frustum].each_with_index do |m, i|
      rim = M.edges_where(m) { |a, b| a[2] == b[2] && a[2] > 0 }
      MODES.each do |mode|
        assert_round_trip(m, rim, mode, 0.8, 4, false, "prism #{i} rim")
        assert_round_trip(m, M.edges(m), mode, 0.5, 4, false, "prism #{i} all")
      end
    end
  end

  def test_stepped_solids
    [M.stepped, M.stepped_flush(false), M.stepped_flush(true)].each_with_index do |m, i|
      MODES.each { |mode| assert_round_trip(m, M.edges(m), mode, 0.6, 4, false, "stepped #{i}") }
    end
  end

  # An edge split by an extra point: reverts to one straight edge (the
  # extra point on it is gone, the shape is the same).
  def test_split_edge
    m = M.split_box
    MODES.each do |mode|
      pts, faces, region, = H.rounded(m, M.edges(m), :mode => mode, :offset => 2.0, :segments => 6)
      assert_empty H.compare(M.box, H.revert(pts, faces, region)), mode.to_s
    end
  end

  # Box whose top is split in two faces by a line across it (x = 5).
  def split_top_box
    m = M.box
    m.points << [5.0, 0.0, 10.0] << [5.0, 10.0, 10.0]
    faces = m.faces.reject { |f| f[:normal][2] > 0.5 }
    faces.each do |f|
      f[:loops] = f[:loops].map do |lp|
        lp.each_with_index.flat_map do |v, i|
          w = lp[(i + 1) % lp.size]
          if [v, w] == [5, 4] then [v, 8]
          elsif [v, w] == [7, 6] then [v, 9]
          else [v]
          end
        end
      end
    end
    faces << M.face([[4, 8, 9, 7]], m.points) << M.face([[8, 5, 6, 9]], m.points)
    MeshHelpers::Mesh.new(m.points, faces)
  end

  # The corners where the dividing line meets a rounded edge come back
  # from the line's direction (the two halves lie in one plane).
  def test_face_split_by_line
    m = split_top_box
    sel = M.edges(m).reject { |a, b| [a, b].sort == [8, 9] }
    MODES.each { |mode| assert_round_trip(m, sel, mode, 2.0, 6, false, 'split top') }
  end

  # The radius is reduced where it does not fit; still reverts exactly.
  def test_reduced_radius
    m = M.box(10, 10, 3)
    MODES.each { |mode| assert_round_trip(m, M.edges(m), mode, 5.0, 6, false, 'thin box') }
  end

  # Random star-shaped prisms, random edges, modes, radii and segments.
  def test_random_prisms
    rng = Random.new(7)
    bad = []
    80.times do |it|
      n = 3 + rng.rand(9)
      poly = (0...n).map do |i|
        a = 2 * Math::PI * (i + 0.4 * rng.rand) / n
        r = 3 + 8 * rng.rand
        [r * Math.cos(a), r * Math.sin(a)]
      end
      m = M.prism(poly, 2 + 8 * rng.rand)
      all = M.edges(m)
      sel = rng.rand < 0.4 ? all : all.select { rng.rand < 0.5 }
      sel = [all[rng.rand(all.size)]] if sel.empty?
      mode = MODES[rng.rand(3)]
      r = 0.2 + 2 * rng.rand
      seg = 1 + rng.rand(8)
      begin
        diffs = round_trip(m, sel, mode, r, seg)
        bad << "#{it} #{mode} r=#{r.round(3)} seg=#{seg} edges=#{sel.size}: #{diffs.join(', ')}" unless diffs.empty?
      rescue R::Error => e
        bad << "#{it} #{mode} r=#{r.round(3)} seg=#{seg} edges=#{sel.size}: #{e.message}"
      end
    end
    assert_empty bad, bad.first(10).join("\n")
  end

  # --- what must be refused ------------------------------------------------

  def surface_of_box(mode = :round)
    H.rounded(M.box, M.edges(M.box), :mode => mode, :offset => 2.0, :segments => 6)
  end

  def test_whole_solid_selected
    pts, faces, = surface_of_box
    e = assert_raises(R::Error) { R.solve(pts, faces, (0...faces.size).to_a) }
    assert_match(/no outline/, e.message)
  end

  def test_flat_face_selected_with_surface
    pts, faces, region, = surface_of_box
    top = (0...faces.size).find { |f| !region.include?(f) && faces[f][:normal][2] > 0.99 }
    # the surface and the flat top face: the top leans toward no face
    assert_raises(R::Error) { R.solve(pts, faces, region + [top]) }
  end

  def test_part_of_smooth_surface
    pts, faces, region, eng = surface_of_box
    refute_empty eng.soft
    # one face of a corner patch region only: its neighbours continue
    # smoothly into faces that are not selected
    part = region.first(3)
    assert_raises(R::Error) { R.solve(pts, faces, part) }
  end

  def test_nothing_selected
    pts, faces, = surface_of_box
    assert_raises(R::Error) { R.solve(pts, faces, []) }
  end
end
