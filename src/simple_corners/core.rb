# Simple Corners - geometry engine.
#
# Pure Ruby (no SketchUp API), compatible with Ruby 2.2 (SketchUp 2017).
# The engine works on an abstract polygon mesh:
#
#   points : Array of [x, y, z] (index = vertex id)
#   faces  : Array of { :loops => [[vid, ...], ...], :normal => [x, y, z] }
#            loops[0] is the outer loop, the rest are holes.
#   edges  : Array of [vid, vid] - the edges to round / bevel.
#
# Overview of the method (for each end vertex V of a selected edge):
#   1. Walk the fan of faces/edges around V.
#   2. Place new "corner points" in every face around V:
#        m - where the offset lines of two selected edges meet,
#        q - where the offset line of a selected edge crosses an unselected edge,
#        p - offset point used when the face is reflex/straight at V.
#   3. Build the end profile (arc) of every selected edge between its two
#      corner points. Profiles are rational quadratic curves defined by a
#      start, a middle point on the edge (or V) and an end point, so they are
#      tangent to both faces.
#   4. The ring of corner points + profiles around V is the corner patch.
#      Shared profiles cancel out (mitre), planar patches merge into a face,
#      the rest is filled according to the mode (round / sharp / bevel).
# Then every selected edge gets a strip between its two end profiles, and
# every face touching V gets its loop rebuilt with the new corner points.
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

module SimpleCorners
  module Core
    class Error < StandardError; end

    # The radius does not fit at some corners (vertex ids in #vertices).
    class OffsetError < Error
      # Corners where the offset does not fit, and the selected edges whose
      # offsets cause it (when known).
      attr_reader :vertices, :edges

      def initialize(msg, vertices, edges = [])
        super(msg)
        @vertices = vertices
        @edges = edges
      end
    end

    # Small vector helpers on [x, y, z] arrays.
    module V
      module_function

      def sub(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def add(a, b)
        [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
      end

      def mul(a, s)
        [a[0] * s, a[1] * s, a[2] * s]
      end

      def dot(a, b)
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
      end

      def cross(a, b)
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
      end

      def len(a)
        Math.sqrt(dot(a, a))
      end

      def dist(a, b)
        len(sub(a, b))
      end

      def norm(a)
        l = len(a)
        l > 0.0 ? mul(a, 1.0 / l) : [0.0, 0.0, 0.0]
      end

      def lerp(a, b, t)
        [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
      end

      def avg(list)
        s = [0.0, 0.0, 0.0]
        list.each { |p| s = add(s, p) }
        mul(s, 1.0 / list.size)
      end

      # Newell normal of a polygon (length = 2 * area).
      def newell(pts)
        n = [0.0, 0.0, 0.0]
        k = pts.size
        k.times do |i|
          a = pts[i]
          b = pts[(i + 1) % k]
          n[0] += (a[1] - b[1]) * (a[2] + b[2])
          n[1] += (a[2] - b[2]) * (a[0] + b[0])
          n[2] += (a[0] - b[0]) * (a[1] + b[1])
        end
        n
      end
    end

    class Engine
      MODES = [:round, :sharp, :bevel].freeze
      # Minimum cosine used to decide that an offset line really crosses a
      # neighbour edge (below that, about 10 degrees from straight, the face
      # is treated as straight/reflex at that corner).
      EPS_DIR = 0.17
      # Mitres between strips whose edges turn by less than ~35 degrees are
      # softened (curves made of short segments).
      SMOOTH_MITRE_COS = 0.82
      # Shape factors of the general (non spherical) round corner.
      APEX_REACH = 0.65
      HERMITE_LEN = 1.1
      TANGENT_WEIGHTS = [1.0, 0.75, 0.5, 0.25, 0.0].freeze
      MAX_FOLD_DEG = 45.0
      CUSP_DEG = 35.0
      # Patches deviating less than this fraction of their size from a
      # plane are filled with a simple fan.
      FLAT_PATCH = 0.05
      # Automatic radius reduction at corners where the radius does not fit.
      MAX_FIT_STEPS = 40
      FIT_FACTOR = 0.75
      # Below this fraction of the radius, blamed edges that still do not
      # fit widen the blame to all edges at their corners.
      WIDEN_BLAME = 0.1
      REFINE_ROUNDS = 4
      FAIR_ITER = 400

      attr_reader :points, :face_loops, :new_polys, :soft, :diagonals, :removed_edges, :trimmed_edges,
                  :warnings, :reduced

      # opts: :mode (:round, :sharp, :bevel), :offset (Float > 0),
      #       :segments (Integer, ignored for bevel),
      #       :format (lambda converting a length to a String, for messages)
      def initialize(points, faces, sel_edges, opts = {})
        @points = points.map { |p| [p[0].to_f, p[1].to_f, p[2].to_f] }
        @faces = faces
        @sel_input = sel_edges
        @mode = (opts[:mode] || :round).to_sym
        raise Error, "Unknown mode #{@mode}" unless MODES.include?(@mode)
        @offset = opts[:offset].to_f
        # Optional per-edge offsets ({[a, b] (a < b) => offset}), see
        # Engine.fit. Each edge has one offset along its whole length.
        @offsets = opts[:offsets] || {}
        @reduced = {}
        segs = (opts[:segments] || 6).to_i
        @segs = @mode == :bevel ? 1 : [[segs, 1].max, 64].min
        @segs = 2 if @mode == :sharp && @segs < 2
        @fmt = opts[:format] || lambda { |x| format('%.4g', x) }
        # Tuning/testing knobs (not exposed in the UI).
        @force_general = opts[:force_general]
        @apex_reach = opts[:apex_reach] || APEX_REACH
        @hermite_len = opts[:hermite_len] || HERMITE_LEN
        @warnings = []
        # Check-only run (used while searching for radii that fit): skips
        # the corner patches and stops after the checks.
        @check_only = opts[:check_only] ? true : false
      end

      # Runs the engine with opts[:offset] where it fits and a smaller offset
      # on the edges at the corners where it does not. Each edge keeps one
      # offset along its whole length (no tapering); edges that continue
      # almost straight through a corner (a chain, e.g. along a polygonal
      # circle) share one. #reduced lists {[a, b] => offset used}.
      # opts[:outline_only]: build only the trimmed face loops (preview).
      def self.fit(points, faces, sel, opts)
        base = opts[:offset].to_f
        by_edge, at = chains(points, sel, opts[:mode].to_s == 'sharp' ? faces : nil)
        # Optional warm start (offsets from a previous fit) and step limit,
        # used by the live preview. The search runs in check-only mode (no
        # corner patches, which are the slow part and do not affect the
        # checks); the full geometry is built once at the end.
        check = opts.merge(:check_only => true)
        dv = (opts[:start_offsets] || {}).dup
        last = nil
        (opts[:max_steps] || MAX_FIT_STEPS).times do
          begin
            new(points, faces, sel, check.merge(:offsets => dv)).run
            dv = refine_fit(points, faces, sel, check, dv, by_edge, at) unless opts[:refine] == false
            eng = new(points, faces, sel, opts.merge(:offsets => dv, :check_only => opts[:outline_only] ? true : false))
            eng.run
            eng.instance_variable_set(:@reduced, dv)
            return eng
          rescue OffsetError => err
            last = err
            groups = blamed_groups(err, by_edge, at)
            # Blamed edges already tiny and still no fit: the cause is
            # elsewhere at those corners, so shrink all their edges.
            if !groups.empty? && groups.all? { |g| (dv[g.first] || base) < base * WIDEN_BLAME }
              groups = (groups + blamed_groups(OffsetError.new('', err.vertices), by_edge, at)).uniq
            end
            groups.each do |g|
              val = (dv[g.first] || base) * FIT_FACTOR
              g.each { |k| dv[k] = val }
            end
            break if groups.empty? || dv.values.min < base * 0.005
          end
        end
        raise Error, "#{last ? last.message : 'The radius does not fit.'} Even a much smaller radius does not fit there."
      end

      # Chains of selected edges: {edge key => its chain (list of keys)} and
      # {vertex => selected edge keys at it}. With faces (mitred mode), edges
      # of the same kind (both convex or both concave) meeting at a corner
      # are chained too: a mitre needs matching profiles, like mouldings.
      def self.chains(points, sel, faces = nil)
        keys = sel.map { |a, b| a < b ? [a, b] : [b, a] }.uniq
        parent = {}
        keys.each { |k| parent[k] = k }
        find = lambda do |k|
          k = parent[k] while parent[k] != k
          k
        end
        at = Hash.new { |h, v| h[v] = [] }
        keys.each { |k| at[k[0]] << k; at[k[1]] << k }
        dir = lambda do |k, v|
          o = k[0] == v ? k[1] : k[0]
          d = V.sub(points[o].map(&:to_f), points[v].map(&:to_f))
          V.len(d) > 0.0 ? V.norm(d) : nil
        end
        convex = faces ? edge_convexity(points, faces, keys) : {}
        at.each do |v, ks|
          ks.combination(2).each do |a, b|
            da = dir.call(a, v)
            db = dir.call(b, v)
            same_kind = !convex[a].nil? && convex[a] == convex[b]
            next unless da && db && (V.dot(da, db) < -SMOOTH_MITRE_COS || same_kind)
            ra = find.call(a)
            rb = find.call(b)
            parent[ra] = rb unless ra == rb
          end
        end
        groups = Hash.new { |h, r| h[r] = [] }
        keys.each { |k| groups[find.call(k)] << k }
        by_edge = {}
        groups.each_value { |g| g.each { |k| by_edge[k] = g } }
        [by_edge, at]
      end

      # {edge key => true (convex) / false (concave)} for edges with two faces.
      def self.edge_convexity(points, faces, keys)
        want = {}
        keys.each { |k| want[k] = [] }
        faces.each_with_index do |f, fi|
          f[:loops].each do |lp|
            lp.each_with_index do |a, i|
              b = lp[(i + 1) % lp.size]
              k = a < b ? [a, b] : [b, a]
              want[k] << fi if want.key?(k)
            end
          end
        end
        res = {}
        want.each do |k, fis|
          next unless fis.size == 2
          f1, f2 = fis.map { |fi| faces[fi] }
          p0 = points[k[0]].map(&:to_f)
          c2 = f2[:loops][0].map { |i| points[i].map(&:to_f) }
          c2 = c2.inject([0.0, 0.0, 0.0]) { |acc, q| V.add(acc, q) }.map { |x| x / c2.size }
          side = V.dot(V.sub(c2, p0), V.norm(f1[:normal]))
          res[k] = side < 0.0 if side.abs > 1e-12
        end
        res
      end

      # Chains of the edges an OffsetError blames (or of all edges at the
      # blamed corners, if it names no edges).
      def self.blamed_groups(err, by_edge, at)
        keys = err.edges
        keys = err.vertices.flat_map { |v| at.key?(v) ? at[v] : [] } if keys.empty?
        groups = {}
        keys.each do |k|
          g = by_edge[k] || [k]
          groups[g.first] = g
        end
        groups.values
      end

      # After a fit: try to bring reduced edges back up a little (a few
      # rounds), keeping the largest offsets that still fit. When growing
      # all of them fails, the chains at the blamed corners stay and the
      # others grow. Returns the offsets.
      def self.refine_fit(points, faces, sel, opts, dv, by_edge, at)
        base = opts[:offset].to_f
        step = 1.0 / FIT_FACTOR
        REFINE_ROUNDS.times do
          step = Math.sqrt(step)
          grow = dv.keys.select { |k| dv[k] < base }.map { |k| by_edge[k] || [k] }.uniq
          3.times do
            break if grow.empty?
            trial = dv.dup
            grow.each { |g| g.each { |k| trial[k] = [(dv[k] || base) * step, base].min } }
            trial.delete_if { |_k, d| d >= base }
            begin
              new(points, faces, sel, opts.merge(:offsets => trial)).run
              dv = trial
              break
            rescue OffsetError => err
              bad = {}
              blamed_groups(err, by_edge, at).each { |g| g.each { |k| bad[k] = true } }
              left = grow.reject { |g| g.any? { |k| bad[k] } }
              break if left.size == grow.size
              grow = left
            end
          end
        end
        dv
      end

      # Segments of the rebuilt face loops that are not original edges: the
      # lines where the new surfaces meet the original faces (used by the
      # preview; available after a check-only run too).
      def outline_segments
        orig = {}
        @faces.each do |f|
          f[:loops].each { |lp| lp.each_with_index { |a, i| orig[ekey(a, lp[(i + 1) % lp.size])] = true } }
        end
        segs = {}
        (@face_loops || {}).each_value do |loops|
          loops.each do |lp|
            lp.each_with_index do |a, i|
              b = lp[(i + 1) % lp.size]
              k = ekey(a, b)
              segs[k] = true unless a == b || orig[k]
            end
          end
        end
        segs.keys
      end

      def run
        raise Error, 'The offset must be greater than zero.' unless @offset > 0.0
        setup_tolerance
        build_topology
        filter_selection
        raise Error, 'No edge can be processed. Edges must border exactly two non-coplanar faces.' if @sel.empty?
        @end_prof = {}
        @corner = {}
        @trim = {}
        @prof_cache = {}
        @prof_seg = {}
        @soft = {}
        @diagonals = {}
        @viol = {}
        @viol_edges = {}
        @trim_src = {}
        @sel_at = Hash.new { |h, v| h[v] = [] }
        @sel.each_key { |k| @sel_at[k[0]] << k; @sel_at[k[1]] << k }
        @new_polys = []
        @removed = {}
        verts = {}
        @sel.each_key { |k| verts[k[0]] = true; verts[k[1]] = true }
        verts.keys.sort.each { |v| process_vertex(v) }
        check_offsets
        build_face_loops
        # Crossing faces are usually a consequence of the corners above:
        # check them once those fit.
        check_face_loops if @viol.empty?
        unless @viol.empty?
          raise OffsetError.new("The radius does not fit at #{@viol.size} corner(s).", @viol.keys, @viol_edges.keys)
        end
        return self if @check_only
        build_strips
        orient_polys
        @removed_edges = @removed.keys
        # Unselected edges that were shortened (their remaining part keeps
        # its properties).
        @trimmed_edges = @trim.keys.map(&:first).uniq.reject { |k| @sel.key?(k) }
        self
      end

      private

      # ------------------------------------------------------------------
      # Setup
      # ------------------------------------------------------------------

      def setup_tolerance
        lo = [Float::INFINITY] * 3
        hi = [-Float::INFINITY] * 3
        @points.each do |p|
          3.times do |i|
            lo[i] = p[i] if p[i] < lo[i]
            hi[i] = p[i] if p[i] > hi[i]
          end
        end
        ext = @points.empty? ? 1.0 : (0..2).map { |i| hi[i] - lo[i] }.max
        ext = 1.0 if ext <= 0.0
        @scale = [ext, @offset].max
        @tol = @scale * 1e-9
        @ptol = @scale * 1e-7 # planarity tolerance
        @area_tol = (@offset * 1e-6)**2
      end

      def ekey(a, b)
        a < b ? [a, b] : [b, a]
      end

      def new_point(c)
        @points << c
        @points.size - 1
      end

      def build_topology
        @edge_faces = Hash.new { |h, k| h[k] = [] }
        @vert_faces = Hash.new { |h, k| h[k] = [] }
        @inward = {}
        @faces.each_with_index do |f, fi|
          nrm = V.norm(f[:normal])
          f[:loops].each_with_index do |lp, li|
            pts = lp.map { |v| @points[v] }
            ccw = V.dot(V.newell(pts), nrm) > 0.0
            # Face material lies left of the traversal for a CCW outer loop
            # and for a CW hole; flip otherwise.
            s = ((li == 0) == ccw) ? 1.0 : -1.0
            n = lp.size
            lp.each_with_index do |a, i|
              b = lp[(i + 1) % n]
              k = ekey(a, b)
              @edge_faces[k] << fi
              @vert_faces[a] << fi
              dir = V.sub(@points[b], @points[a])
              @inward[[fi, k]] = V.norm(V.mul(V.cross(nrm, dir), s))
            end
          end
        end
      end

      def filter_selection
        @sel = {}
        skipped = 0
        @sel_input.each do |a, b|
          next if a == b
          k = ekey(a, b)
          fs = @edge_faces.key?(k) ? @edge_faces[k] : []
          if fs.size != 2 || fs[0] == fs[1]
            skipped += 1
            next
          end
          n1 = V.norm(@faces[fs[0]][:normal])
          n2 = V.norm(@faces[fs[1]][:normal])
          # Coplanar faces (or a knife fold): nothing to round.
          next if V.len(V.cross(n1, n2)) < 1e-6
          @sel[k] = true
        end
        @warnings << "#{skipped} edge(s) skipped: they do not border exactly two faces." if skipped > 0
      end

      # ------------------------------------------------------------------
      # Vertex processing
      # ------------------------------------------------------------------

      # Returns [edges, faces] in cyclic order: faces[i] lies between
      # edges[i] and edges[i + 1].
      def build_fan(v)
        fis = @vert_faces[v]
        fe = {}
        fis.each do |fi|
          if fe.key?(fi)
            raise Error, "Non-manifold geometry at #{fmt_point(v)}: a face touches this vertex twice."
          end
          found = nil
          @faces[fi][:loops].each do |lp|
            i = lp.index(v)
            next unless i
            n = lp.size
            found = [ekey(lp[(i - 1) % n], v), ekey(v, lp[(i + 1) % n])]
          end
          fe[fi] = found
        end
        ef = Hash.new { |h, k| h[k] = [] }
        fe.each { |fi, pair| ef[pair[0]] << fi; ef[pair[1]] << fi }
        ef.each_value do |l|
          next if l.size == 2
          raise Error, "Cannot process the corner at #{fmt_point(v)}: the geometry around it is open or non-manifold (every edge there must border exactly two faces)."
        end
        start = fe.keys.first
        es = []
        fs = []
        fi = start
        e = fe[fi][0]
        loop do
          es << e
          fs << fi
          a, b = fe[fi]
          e = (a == e) ? b : a
          fi = (ef[e] - [fi]).first
          break if fi == start
          if fi.nil? || fs.size > fe.size
            raise Error, "Cannot process the corner at #{fmt_point(v)}: unexpected face arrangement."
          end
        end
        if fs.size != fe.size
          raise Error, "Cannot process the corner at #{fmt_point(v)}: the faces around it form more than one fan."
        end
        [es, fs]
      end

      def fmt_point(v)
        p = @points[v]
        "(#{@fmt.call(p[0])}, #{@fmt.call(p[1])}, #{@fmt.call(p[2])})"
      end

      # Meeting point of the offset lines of edges a and b inside a face
      # (at distances d_a and d_b from them).
      def meet(pv, da, ua, ub, d_a, d_b)
        den = V.dot(da, ub)
        x = den.abs < 1e-9 ? 0.0 : (d_b - d_a * V.dot(ua, ub)) / den
        V.add(pv, V.add(V.mul(da, x), V.mul(ua, d_a)))
      end

      def edge_offset(k)
        @offsets[k] || @offset
      end

      def process_vertex(v)
        es, fs = build_fan(v)
        n = es.size
        sel = es.map { |k| @sel.key?(k) }
        return unless sel.include?(true)
        pv = @points[v]
        ds = es.map { |k| edge_offset(k) }
        dirs = []
        lens = []
        es.each do |k|
          o = k[0] == v ? k[1] : k[0]
          dv = V.sub(@points[o], pv)
          lens << V.len(dv)
          dirs << V.norm(dv)
        end
        uin = lambda { |fi, k| @inward[[fi, k]] }

        # q points: where offset lines of selected edges cross unselected ones.
        cand = Array.new(n) { [] }
        hits = {}
        n.times do |i|
          ia = i
          ib = (i + 1) % n
          fi = fs[i]
          if sel[ia] && !sel[ib]
            g = V.dot(dirs[ib], uin.call(fi, es[ia]))
            if g > EPS_DIR
              cand[ib] << [ds[ia] / g, g, es[ia]]
              hits[[i, ib]] = true
            end
          elsif sel[ib] && !sel[ia]
            g = V.dot(dirs[ia], uin.call(fi, es[ib]))
            if g > EPS_DIR
              cand[ia] << [ds[ib] / g, g, es[ib]]
              hits[[i, ia]] = true
            end
          end
        end
        q = Array.new(n)
        n.times do |j|
          next if cand[j].empty?
          # Weighted by how cleanly each offset line crosses the edge.
          wsum = cand[j].inject(0.0) { |acc, (_t, g)| acc + g * g }
          t = cand[j].inject(0.0) { |acc, (tt, g)| acc + tt * g * g } / wsum
          if t >= lens[j] - @tol
            # Does not fit: remember the corner and the edges whose offset
            # lines reach too far, continue with a stand-in.
            @viol[v] = true
            cand[j].each { |c3| blame_edge(c3[2]) }
            t = lens[j] * 0.5
          end
          @trim_src[[es[j], v]] = cand[j].map { |c3| c3[2] }
          q[j] = new_point(V.add(pv, V.mul(dirs[j], t)))
          @trim[[es[j], v]] = t
          @removed[es[j]] = true
        end

        # Corner sequences C[i] for every face, in fan order (from edge i
        # side to edge i+1 side).
        mpts = {}
        c = Array.new(n)
        n.times do |i|
          ia = i
          ib = (i + 1) % n
          fi = fs[i]
          if sel[ia] && sel[ib]
            m = new_point(meet(pv, dirs[ia], uin.call(fi, es[ia]), uin.call(fi, es[ib]), ds[ia], ds[ib]))
            mpts[m] = true
            c[i] = [m]
          elsif sel[ia]
            if hits[[i, ib]]
              c[i] = [q[ib]]
            else
              # Straight or reflex corner: offset point; the corner itself
              # is kept only if nothing cuts the other edge (fillet end cap).
              p = new_point(V.add(pv, V.mul(uin.call(fi, es[ia]), ds[ia])))
              c[i] = q[ib] ? [p, q[ib]] : [p, v]
            end
          elsif sel[ib]
            if hits[[i, ia]]
              c[i] = [q[ia]]
            else
              p = new_point(V.add(pv, V.mul(uin.call(fi, es[ib]), ds[ib])))
              c[i] = q[ia] ? [q[ia], p] : [v, p]
            end
          else
            qa = q[ia]
            qb = q[ib]
            if qa && qb && V.dot(dirs[ib], uin.call(fi, es[ia])) > EPS_DIR
              c[i] = [qa, qb] # cut the corner of this face
            else
              c[i] = []
              c[i] << qa if qa
              c[i] << v
              c[i] << qb if qb
            end
          end
        end

        # End profiles of the selected edges.
        profs = Array.new(n)
        mids = Array.new(n)
        # Two selected edges whose end profiles join the same two points meet
        # in a mitre: they share one profile whose middle point is the
        # vertex. Other profiles use the point of the edge under their
        # middle (the vertex itself would skew them along the edge).
        ends = {}
        n.times do |i|
          next unless sel[i]
          k = [c[(i - 1) % n].last, c[i].first].sort
          ends[k] = (ends[k] || 0) + 1
        end
        n.times do |i|
          next unless sel[i]
          lid = c[(i - 1) % n].last
          rid = c[i].first
          shared = v
          mc = pv
          mitre = ends[[lid, rid].sort] > 1
          if !mitre
            mid = V.lerp(@points[lid], @points[rid], 0.5)
            # Clamped to the edge: a middle point behind the vertex would
            # make the profile bulge out of the solid.
            along = V.dot(V.sub(mid, pv), dirs[i])
            along = 0.0 if along < 0.0
            along = lens[i] * 0.5 if along > lens[i] * 0.5
            mc = V.add(pv, V.mul(dirs[i], along))
            if V.dist(mc, pv) < ds[i] * 1e-6
              mc = pv
            else
              shared = nil
            end
          end
          ids = lid == rid ? [lid] : profile(lid, rid, mc, shared)
          profs[i] = ids
          mids[i] = mc
          @end_prof[[es[i], v]] = [ids, fs[(i - 1) % n]]
          (0...ids.size - 1).each { |j| @prof_seg[ekey(ids[j], ids[j + 1])] = true }
        end

        # Profiles shared by two (nearly) collinear edges, e.g. along a
        # polygonal circle: smooth transition instead of a visible mitre.
        sidx = (0...n).select { |i| sel[i] }
        sidx.each do |i|
          sidx.each do |j|
            next unless i < j
            next unless profs[i].size > 1 && profs[i] == profs[j].reverse
            next unless V.dot(dirs[i], dirs[j]) < -SMOOTH_MITRE_COS
            mark_soft_chain(profs[i])
          end
        end

        # Patch boundary around the vertex.
        b = []
        n.times do |i|
          b.concat(profs[i]) if sel[i]
          b.concat(c[i])
        end
        b = dedupe_cyclic(b)
        size0 = b.size
        b = cancel_spurs(b)
        cancelled = b.size != size0
        if b.size >= 3 && !try_merge(b, c, fs)
          src = fs[sidx.first]
          build_patch(v, b, es, fs, sel, dirs, profs, mids, c, cancelled, src) unless @check_only
        end

        n.times { |i| @corner[[fs[i], v]] = [c[i], es[i]] }
        sidx.each { |i| @removed[es[i]] = true }
      end

      # Rational quadratic profile from l to r with middle (control) point m.
      # Exact circle when |l - m| == |r - m|; points evenly spaced by angle.
      def profile_coords(l, m, r, nseg)
        return [l, r] if nseg <= 1
        a = V.sub(l, m)
        b = V.sub(r, m)
        la = V.len(a)
        lb = V.len(b)
        cosa = (la > 0.0 && lb > 0.0) ? V.dot(a, b) / (la * lb) : -1.0
        cosa = 1.0 if cosa > 1.0
        cosa = -1.0 if cosa < -1.0
        theta = (Math::PI - Math.acos(cosa)) / 2.0 # half of the arc sweep
        res = []
        (0..nseg).each do |j|
          f = j.to_f / nseg
          if theta < 1e-6
            res << V.lerp(l, r, f)
            next
          end
          w = Math.cos(theta)
          u = Math.tan(theta * (2.0 * f - 1.0) / 2.0) / Math.tan(theta / 2.0)
          t = (u + 1.0) / 2.0
          b0 = (1.0 - t)**2
          b1 = 2.0 * t * (1.0 - t) * w
          b2 = t * t
          den = b0 + b1 + b2
          res << V.add(m, V.add(V.mul(a, b0 / den), V.mul(b, b2 / den)))
        end
        res[0] = l
        res[-1] = r
        res
      end

      # Profile ids from lid to rid. Profiles whose middle point is the
      # vertex itself are cached so two edges meeting at a mitre share the
      # very same points.
      def profile(lid, rid, mc, shared)
        if shared
          lo, hi = lid < rid ? [lid, rid] : [rid, lid]
          key = [lo, hi, shared]
          ids = @prof_cache[key]
          unless ids
            cs = profile_coords(@points[lo], mc, @points[hi], @segs)
            ids = [lo] + cs[1..-2].map { |x| new_point(x) } + [hi]
            @prof_cache[key] = ids
          end
          return lid == lo ? ids : ids.reverse
        end
        cs = profile_coords(@points[lid], mc, @points[rid], @segs)
        [lid] + cs[1..-2].map { |x| new_point(x) } + [rid]
      end

      def dedupe_cyclic(ids)
        out = []
        ids.each { |i| out << i unless out.last == i }
        out.pop while out.size > 1 && out.last == out.first
        out
      end

      # Removes back-and-forth sections (a, b, a) from a cyclic list.
      def cancel_spurs(b)
        b = b.dup
        loop do
          return [] if b.size < 3
          n = b.size
          idx = (0...n).find { |i| b[(i - 1) % n] == b[(i + 1) % n] }
          return b unless idx
          i1 = (idx + 1) % n
          [idx, i1].sort.reverse_each { |k| b.delete_at(k) }
          b = dedupe_cyclic(b)
        end
      end

      def planar?(pts, tol)
        return true if pts.size <= 3
        nrm = V.newell(pts)
        l = V.len(nrm)
        return true if l <= 0.0
        nrm = V.mul(nrm, 1.0 / l)
        c = V.avg(pts)
        pts.all? { |p| V.dot(V.sub(p, c), nrm).abs <= tol }
      end

      # A planar patch lying in the plane of a face that shares a straight
      # part of its boundary is merged into that face.
      def try_merge(b, c, fs)
        pts = b.map { |id| @points[id] }
        return false unless planar?(pts, @ptol)
        c.each_with_index do |ci, i|
          next if ci.size < 2
          nrm = V.norm(@faces[fs[i]][:normal])
          o = @points[ci[0]]
          next unless pts.all? { |p| V.dot(V.sub(p, o), nrm).abs <= @ptol }
          s = find_run(b, ci)
          next unless s
          nb = b.size
          comp = [b[s]]
          (1..(nb - ci.size + 1)).each { |j| comp << b[(s - j) % nb] }
          c[i] = comp
          return true
        end
        false
      end

      def find_run(b, ci)
        nb = b.size
        nb.times do |s|
          ok = true
          ci.each_with_index do |id, j|
            next if b[(s + j) % nb] == id
            ok = false
            break
          end
          return s if ok
        end
        nil
      end

      # ------------------------------------------------------------------
      # Corner patches
      # ------------------------------------------------------------------

      def build_patch(v, b, es, _fs, sel, dirs, profs, mids, c, cancelled, src)
        @cur_kind = :patch
        pts = b.map { |id| @points[id] }
        if b.size == 3 || planar?(pts, @ptol)
          add_poly(b, src)
          return
        end
        # The original vertex is part of the patch (unselected edges still
        # end there): a fan of triangles from it, i.e. a small cone that
        # blends the strips back into the sharp vertex.
        vi = b.index(v)
        if vi
          @cur_kind = :patch_fan
          m = b.size
          polys = []
          (1...m - 1).each { |k| polys.concat(add_poly([v, b[(vi + k) % m], b[(vi + k + 1) % m]], src)) }
          mark_soft_polys(polys, boundary_pairs(b), @mode != :bevel)
          return
        end
        # Almost flat corner (e.g. on a faceted dome): a simple fan.
        if nearly_flat?(pts)
          flat_fan(v, b, pts, src)
          return
        end
        if @mode == :bevel
          @cur_kind = :patch_bevel
          cid = new_point(V.avg(pts))
          polys = []
          m = b.size
          m.times { |i| polys.concat(add_poly([b[i], b[(i + 1) % m], cid], src)) }
          mark_soft_polys(polys, boundary_pairs(b), false)
          return
        end
        if @mode == :sharp && !cancelled && sel.all? && c.all? { |x| x.size == 1 }
          @cur_kind = :patch_sharp
          return if sharp_fill(es, dirs, profs, c, src)
        end
        round_fill(v, b, es, sel, dirs, profs, mids, src)
      end

      def nearly_flat?(pts)
        nrm = V.newell(pts)
        return true if V.len(nrm) <= 0.0
        nrm = V.norm(nrm)
        c = V.avg(pts)
        size = pts.map { |p| V.dist(p, c) }.max
        dev = pts.map { |p| V.dot(V.sub(p, c), nrm).abs }.max
        dev < FLAT_PATCH * size
      end

      # Fan from a centre point lifted a little toward the original vertex.
      def flat_fan(v, b, pts, src)
        @cur_kind = :patch_flat
        cid = new_point(V.lerp(V.avg(pts), @points[v], 0.25))
        m = b.size
        polys = []
        m.times { |i| polys.concat(add_poly([b[i], b[(i + 1) % m], cid], src)) }
        mark_soft_polys(polys, boundary_pairs(b), @mode != :bevel)
      end

      def boundary_pairs(b)
        h = {}
        m = b.size
        m.times { |i| h[ekey(b[i], b[(i + 1) % m])] = true }
        h
      end

      # Marks every edge of polys soft, except boundary edges (which are
      # soft only when they are profile segments and soften_profiles is set).
      def mark_soft_polys(polys, boundary, soften_profiles, hard = {})
        # Mitred mode: a corner that gets a smooth blend instead of exact
        # ridges keeps visible lines where it meets the strips.
        soften_profiles = false if @mode == :sharp && @cur_kind != :patch_sharp
        polys.each do |ids|
          k = ids.size
          k.times do |i|
            e = ekey(ids[i], ids[(i + 1) % k])
            next if hard[e]
            if boundary[e]
              @soft[e] = true if soften_profiles && @prof_seg[e]
            else
              @soft[e] = true
            end
          end
        end
      end

      def mark_soft_chain(ids)
        (0...ids.size - 1).each { |j| @soft[ekey(ids[j], ids[j + 1])] = true }
      end

      # Smooth corner: rings of points from the boundary to an apex, either
      # projected on a sphere (regular convex/concave corners) or relaxed.
      def round_fill(v, b, es, sel, dirs, profs, mids, src)
        m = b.size
        rings = [(@segs + 1) / 2, 1].max
        pts = b.map { |id| @points[id] }
        bc = V.avg(pts)
        bset = {}
        b.each { |id| bset[id] = true }
        all_prof = (0...m).all? { |i| @prof_seg[ekey(b[i], b[(i + 1) % m])] }
        @cur_kind = :patch_cusp
        return if cusp_fill(b, pts, es, sel, profs, src)
        @cur_kind = :patch_grid
        return if !@force_general && structured_fill(b, es, sel, dirs, profs, mids, src)
        @cur_kind = :patch_radial

        centers = []
        prof_mid_pts = []
        es.each_index do |i|
          next unless sel[i]
          ids = profs[i]
          next if ids.size < 2
          next unless bset[ids[0]] && bset[ids[-1]]
          l = @points[ids[0]]
          r = @points[ids[-1]]
          mc = mids[i]
          a = V.sub(l, mc)
          bb = V.sub(r, mc)
          ca = V.dot(V.norm(a), V.norm(bb))
          prof_mid_pts << @points[ids[ids.size / 2]]
          next if 1.0 + ca < 1e-3
          centers << V.add(mc, V.mul(V.add(a, bb), 1.0 / (1.0 + ca)))
        end

        sphere = nil
        if all_prof && !centers.empty?
          cs = V.avg(centers)
          rads = pts.map { |p| V.dist(p, cs) }
          ravg = rads.inject(:+) / m
          spread = centers.map { |x| V.dist(x, cs) }.max
          if !@force_general && ravg > @tol && spread < 0.25 * ravg && V.dist(bc, cs) > 1e-3 * ravg
            sphere = [cs, rads, ravg]
          end
        end

        grid = [b]
        if sphere
          cs, rads, ravg = sphere
          apex_c = V.add(cs, V.mul(V.norm(V.sub(bc, cs)), ravg))
          (1...rings).each do |r|
            s = r.to_f / rings
            grid << (0...m).map do |i|
              qq = V.lerp(pts[i], apex_c, s)
              rr = (1.0 - s) * rads[i] + s * ravg
              new_point(V.add(cs, V.mul(V.norm(V.sub(qq, cs)), rr)))
            end
          end
          apex = new_point(apex_c)
        else
          # General corner (fillets of different radii, saddles...): each
          # boundary point starts a cubic Hermite curve that leaves the
          # boundary along the continuation of its strip (tangent
          # continuity) and reaches the apex tangent to the apex plane.
          vs = blended_sphere_rows(b, pts, es, sel, profs, mids, rings)
          if vs && grid_fold([pts] + vs[0], vs[1]) < MAX_FOLD_DEG
            vs[0].each { |row| grid << row.map { |x| new_point(x) } }
            apex = new_point(vs[1])
            emit_ring_polys(grid, apex, m, b, src)
            return
          end
          # Skewed corners (e.g. inner corners) can make those curves cross:
          # the tangents are then blended toward the apex until the patch
          # has no fold.
          tans = boundary_tangents(b, pts, es, sel, dirs, profs, bc)
          na = V.norm(V.newell(pts))
          best = nil
          TANGENT_WEIGHTS.each do |w|
            tw = (0...m).map do |i|
              t = V.lerp(V.norm(V.sub(bc, pts[i])), tans[i], w)
              V.len(t) > 1e-9 ? V.norm(t) : tans[i]
            end
            acw = V.avg((0...m).map { |i| V.add(pts[i], V.mul(tw[i], @apex_reach * V.dist(bc, pts[i]))) })
            rows = (1...rings).map do |r|
              s = r.to_f / rings
              (0...m).map { |i| hermite_to_apex(pts[i], tw[i], acw, na, s) }
            end
            fold = grid_fold([pts] + rows, acw)
            best = [fold, rows, acw] if best.nil? || fold < best[0]
            break if fold < MAX_FOLD_DEG
          end
          # Nothing fold-free: fall back to a simple fan.
          if best[0] > MAX_FOLD_DEG
            flat_fan(v, b, pts, src)
            return
          end
          rows = best[1]
          ac = best[2]
          rows.each { |row| grid << row.map { |x| new_point(x) } }
          apex = new_point(ac)
        end

        emit_ring_polys(grid, apex, m, b, src)
      end

      def emit_ring_polys(grid, apex, m, b, src)
        polys = []
        (0...grid.size - 1).each do |r|
          m.times do |i|
            i1 = (i + 1) % m
            polys.concat(add_poly([grid[r][i], grid[r][i1], grid[r + 1][i1], grid[r + 1][i]], src))
          end
        end
        m.times { |i| polys.concat(add_poly([grid[-1][i], grid[-1][(i + 1) % m], apex], src)) }
        mark_soft_polys(polys, boundary_pairs(b), true)
      end

      # Corner made of fillets of different radii: every boundary point sits
      # on a sphere around the centre of its own fillet; moving inward, the
      # centres and radii blend (smoothly, so the patch stays tangent to the
      # strips) toward a common centre. Returns [rows, apex] or nil.
      def blended_sphere_rows(b, pts, es, sel, profs, mids, rings)
        m = b.size
        seg_edge = {}
        centers = {}
        es.each_index do |i|
          next unless sel[i]
          ids = profs[i]
          next if ids.size < 2
          a = V.sub(@points[ids[0]], mids[i])
          bb = V.sub(@points[ids[-1]], mids[i])
          ca = V.dot(V.norm(a), V.norm(bb))
          next if 1.0 + ca < 1e-3
          centers[i] = V.add(mids[i], V.mul(V.add(a, bb), 1.0 / (1.0 + ca)))
          (0...ids.size - 1).each { |j| seg_edge[ekey(ids[j], ids[j + 1])] = i }
        end
        ck = []
        m.times do |k|
          own = [seg_edge[ekey(b[(k - 1) % m], b[k])], seg_edge[ekey(b[k], b[(k + 1) % m])]].compact.uniq
          own = own.select { |i| centers[i] }
          return nil if own.empty?
          ck << V.avg(own.map { |i| centers[i] })
        end
        uk = (0...m).map { |k| V.norm(V.sub(pts[k], ck[k])) }
        rk = (0...m).map { |k| V.dist(pts[k], ck[k]) }
        cavg = V.avg(ck)
        ua = V.norm(V.avg(uk))
        return nil if V.len(ua) < 1e-6
        ra = rk.inject(:+) / m
        apex = V.add(cavg, V.mul(ua, ra))
        rows = (1...rings).map do |r|
          s = r.to_f / rings
          e = s * s * (3.0 - 2.0 * s)
          (0...m).map do |k|
            c = V.lerp(ck[k], cavg, e)
            rad = rk[k] + (ra - rk[k]) * e
            d = V.norm(V.lerp(uk[k], ua, s))
            V.add(c, V.mul(d, rad))
          end
        end
        [rows, apex]
      end

      # Unit tangent of the corner surface at every boundary point, pointing
      # into the patch: the continuation of the adjacent strip(s),
      # perpendicular to the boundary.
      def boundary_tangents(b, pts, es, sel, dirs, profs, bc)
        seg_edge = {}
        es.each_index do |i|
          next unless sel[i]
          ids = profs[i]
          (0...ids.size - 1).each { |j| seg_edge[ekey(ids[j], ids[j + 1])] = i }
        end
        m = b.size
        perp = lambda do |a, t|
          V.norm(V.sub(a, V.mul(t, V.dot(a, t))))
        end
        (0...m).map do |k|
          pp = pts[(k - 1) % m]
          pc = pts[k]
          pn = pts[(k + 1) % m]
          ep = seg_edge[ekey(b[(k - 1) % m], b[k])]
          en = seg_edge[ekey(b[k], b[(k + 1) % m])]
          if ep && ep == en
            # Inside a profile: continue the strip.
            t = perp.call(V.mul(dirs[ep], -1.0), V.norm(V.sub(pn, pp)))
            next t if V.len(t) > 1e-9
          end
          # Corner of the patch: bisect the angle between both neighbours.
          t = V.add(V.norm(V.sub(pp, pc)), V.norm(V.sub(pn, pc)))
          next V.norm(t) if V.len(t) > 1e-6
          cands = []
          cands << perp.call(V.mul(dirs[ep], -1.0), V.norm(V.sub(pc, pp))) if ep
          cands << perp.call(V.mul(dirs[en], -1.0), V.norm(V.sub(pn, pc))) if en
          cands = cands.reject { |x| V.len(x) < 1e-9 }
          cands.empty? ? V.norm(V.sub(bc, pc)) : V.norm(V.avg(cands))
        end
      end

      # Splits a patch boundary in sides (one per profile / straight part).
      # Returns a list of id lists, each from one patch corner to the next.
      def patch_sides(b, es, sel, profs)
        seg_edge = {}
        es.each_index do |i|
          next unless sel[i]
          ids = profs[i]
          (0...ids.size - 1).each { |j| seg_edge[ekey(ids[j], ids[j + 1])] = i }
        end
        m = b.size
        owner = (0...m).map { |k| seg_edge[ekey(b[k], b[(k + 1) % m])] || -1 - k }
        corners = (0...m).select { |k| owner[(k - 1) % m] != owner[k] }
        return [b + [b[0]]] if corners.empty?
        corners.each_with_index.map do |k, ci|
          k2 = corners[(ci + 1) % corners.size]
          k2 += m if k2 <= k
          (k..k2).map { |j| b[j % m] }
        end
      end

      # Centre and per-point radii of the fillet whose end profile is `side`
      # (nil when the side is not a profile).
      def side_circle(side, es, sel, profs, mids)
        es.each_index do |i|
          next unless sel[i]
          ids = profs[i]
          next unless ids.size == side.size && (ids == side || ids == side.reverse)
          a = V.sub(@points[ids[0]], mids[i])
          bb = V.sub(@points[ids[-1]], mids[i])
          ca = V.dot(V.norm(a), V.norm(bb))
          return nil if 1.0 + ca < 1e-3
          c = V.add(mids[i], V.mul(V.add(a, bb), 1.0 / (1.0 + ca)))
          return [c, side.map { |id| V.dist(@points[id], c) }]
        end
        nil
      end

      # Linear interpolation in an array of values at fractional index t.
      def interp_at(vals, t)
        t = 0.0 if t < 0.0
        t = vals.size - 1.0 if t > vals.size - 1
        i = t.floor
        i = vals.size - 2 if i >= vals.size - 1
        f = t - i
        vals[i] * (1.0 - f) + vals[i + 1] * f
      end

      # Projects x on a sphere whose centre/radius blend those of the sides,
      # weighted by 1 / distance^2 to each side (so the result stays tangent
      # to the fillets near the boundary). sides_d: [[dist, center, radius]].
      def blend_project(x, sides_d)
        wsum = 0.0
        c = [0.0, 0.0, 0.0]
        r = 0.0
        sides_d.each do |d, cc, rr|
          w = 1.0 / [d * d, 1e-12].max
          wsum += w
          c = V.add(c, V.mul(cc, w))
          r += rr * w
        end
        c = V.mul(c, 1.0 / wsum)
        r /= wsum
        dir = V.norm(V.sub(x, c))
        return x if V.len(dir) == 0.0
        V.add(c, V.mul(dir, r))
      end

      # Regular grid for corners with 3 or 4 sides of equal segment count:
      # a triangular lattice (3 sides) or a square grid (4 sides), pushed
      # onto blended spheres when every side is a fillet profile. Avoids the
      # singular apex of a radial fill. Returns false if not applicable or
      # if the result folds.
      def structured_fill(b, es, sel, dirs, profs, mids, src)
        sides = patch_sides(b, es, sel, profs)
        ns = sides.size
        return false unless ns == 3 || ns == 4
        nseg = sides[0].size - 1
        return false unless nseg >= 2 && sides.all? { |s| s.size - 1 == nseg }
        circ = sides.map { |s| side_circle(s, es, sel, profs, mids) }
        project = circ.all?
        pt = lambda { |id| @points[id] }
        nf = nseg.to_f
        rows = [] # rows of [id or coords]
        if ns == 3
          s0, s1, s2 = sides
          rows << s0.dup
          (1...nseg).each do |c|
            left = s2[nseg - c]
            right = s1[c]
            len = nseg - c
            row = [left]
            (1...len).each do |a1|
              a2 = c
              a0 = nseg - c - a1
              x = V.lerp(pt.call(left), pt.call(right), a1.to_f / len)
              if project
                sd = [
                  [a2 / nf, circ[0][0], interp_at(circ[0][1], a1.to_f / (a0 + a1) * nseg)],
                  [a0 / nf, circ[1][0], interp_at(circ[1][1], a2.to_f / (a1 + a2) * nseg)],
                  [a1 / nf, circ[2][0], interp_at(circ[2][1], a0.to_f / (a0 + a2) * nseg)]
                ]
                x = blend_project(x, sd)
              end
              row << x
            end
            row << right
            rows << row
          end
          rows << [s1[nseg]]
          tris = []
          (0...nseg).each do |c|
            ra = rows[c]
            rb = rows[c + 1]
            (0...ra.size - 1).each do |i|
              tris << [[c, i], [c, i + 1], [c + 1, i]]
              tris << [[c, i + 1], [c + 1, i + 1], [c + 1, i]] if i < rb.size - 1
            end
          end
        else
          s0, s1, s2, s3 = sides
          s2r = s2.reverse
          p0 = pt.call(s0[0])
          p1 = pt.call(s1[0])
          p2 = pt.call(s2[0])
          p3 = pt.call(s3[0])
          rows << s0.dup
          (1...nseg).each do |j|
            v = j / nf
            left = s3[nseg - j]
            right = s1[j]
            row = [left]
            (1...nseg).each do |i|
              u = i / nf
              x = V.add(V.add(V.mul(pt.call(s0[i]), 1 - v), V.mul(pt.call(s2r[i]), v)),
                        V.add(V.mul(pt.call(left), 1 - u), V.mul(pt.call(right), u)))
              bil = V.add(V.add(V.mul(p0, (1 - u) * (1 - v)), V.mul(p1, u * (1 - v))),
                          V.add(V.mul(p2, u * v), V.mul(p3, (1 - u) * v)))
              x = V.sub(x, bil)
              if project
                sd = [
                  [v, circ[0][0], interp_at(circ[0][1], i)],
                  [1 - u, circ[1][0], interp_at(circ[1][1], j)],
                  [1 - v, circ[2][0], interp_at(circ[2][1], nseg - i)],
                  [u, circ[3][0], interp_at(circ[3][1], nseg - j)]
                ]
                x = blend_project(x, sd)
              end
              row << x
            end
            row << right
            rows << row
          end
          rows << s2r
          tris = []
          nseg.times do |j|
            nseg.times do |i|
              tris << [[j, i], [j, i + 1], [j + 1, i + 1]]
              tris << [[j, i], [j + 1, i + 1], [j + 1, i]]
            end
          end
        end
        # Fillets of different radii: the blended spheres can bulge, so the
        # grid is faired (thin-plate smoothing with the strips' tangents as
        # boundary condition). Exact sphere corners are kept as they are.
        unless project && uniform_circles?(circ)
          pts = b.map { |id| @points[id] }
          tans = boundary_tangents(b, pts, es, sel, dirs, profs, V.avg(pts))
          tan_by_id = {}
          b.each_with_index { |id, k| tan_by_id[id] = tans[k] }
          fair_lattice!(rows, tris, tan_by_id)
        end
        coord = lambda { |rc| e = rows[rc[0]][rc[1]]; e.is_a?(Array) ? e : @points[e] }
        return false if tri_fold(tris, coord) > MAX_FOLD_DEG
        ids = rows.map { |row| row.map { |e| e.is_a?(Array) ? new_point(e) : e } }
        polys = []
        if ns == 3
          tris.each { |t| polys.concat(add_poly(t.map { |rc| ids[rc[0]][rc[1]] }, src)) }
        else
          nseg.times do |j|
            nseg.times do |i|
              polys.concat(add_poly([ids[j][i], ids[j][i + 1], ids[j + 1][i + 1], ids[j + 1][i]], src))
            end
          end
        end
        mark_soft_polys(polys, boundary_pairs(b), true)
        true
      end

      def uniform_circles?(circ)
        cs = circ.map { |c| c[0] }
        rs = circ.flat_map { |c| c[1] }
        ravg = rs.inject(:+) / rs.size
        cavg = V.avg(cs)
        cs.all? { |c| V.dist(c, cavg) < 0.05 * ravg } && rs.all? { |r| (r - ravg).abs < 0.05 * ravg }
      end

      # Thin-plate (biharmonic) smoothing of the interior points of a
      # lattice. Boundary points stay fixed; one ghost point per boundary
      # point, placed along the strip continuation outside the patch, makes
      # the result leave the boundary tangentially to the strips.
      def fair_lattice!(rows, tris, tan_by_id)
        index = {}
        keys = []
        xs = []
        ys = []
        zs = []
        fixed = []
        rows.each_with_index do |row, r|
          row.each_with_index do |e, i|
            index[[r, i]] = keys.size
            keys << [r, i]
            p = e.is_a?(Array) ? e : @points[e]
            xs << p[0]
            ys << p[1]
            zs << p[2]
            fixed << !e.is_a?(Array)
          end
        end
        nv = keys.size
        nbs = Array.new(nv) { [] }
        tris.each do |t|
          3.times do |i|
            a = index[t[i]]
            c = index[t[(i + 1) % 3]]
            nbs[a] << c unless nbs[a].include?(c)
            nbs[c] << a unless nbs[c].include?(a)
          end
        end
        interior = (0...nv).reject { |k| fixed[k] }
        return if interior.empty?
        # Ghost points (fixed) along the strip continuation.
        gx = Array.new(nv, 0.0)
        gy = Array.new(nv, 0.0)
        gz = Array.new(nv, 0.0)
        gw = Array.new(nv, 0)
        nv.times do |k|
          next unless fixed[k] && !nbs[k].empty?
          r, i = keys[k]
          t = tan_by_id[rows[r][i]]
          next unless t
          h = nbs[k].map { |o| Math.sqrt((xs[o] - xs[k])**2 + (ys[o] - ys[k])**2 + (zs[o] - zs[k])**2) }.inject(:+) / nbs[k].size
          w = [6 - nbs[k].size, 1].max
          gx[k] = (xs[k] - t[0] * h) * w
          gy[k] = (ys[k] - t[1] * h) * w
          gz[k] = (zs[k] - t[2] * h) * w
          gw[k] = w
        end
        inv = (0...nv).map { |k| 1.0 / (nbs[k].size + gw[k]) }
        lx = Array.new(nv, 0.0)
        ly = Array.new(nv, 0.0)
        lz = Array.new(nv, 0.0)
        step = 0.15
        stop = (@offset * 1e-6)**2
        FAIR_ITER.times do
          moved = 0.0
          nv.times do |k|
            sx = gx[k]
            sy = gy[k]
            sz = gz[k]
            nbs[k].each do |o|
              sx += xs[o]
              sy += ys[o]
              sz += zs[o]
            end
            lx[k] = sx * inv[k] - xs[k]
            ly[k] = sy * inv[k] - ys[k]
            lz[k] = sz * inv[k] - zs[k]
          end
          interior.each do |k|
            nb = nbs[k]
            sx = 0.0
            sy = 0.0
            sz = 0.0
            nb.each do |o|
              sx += lx[o]
              sy += ly[o]
              sz += lz[o]
            end
            f = 1.0 / nb.size
            dx = step * (sx * f - lx[k])
            dy = step * (sy * f - ly[k])
            dz = step * (sz * f - lz[k])
            xs[k] -= dx
            ys[k] -= dy
            zs[k] -= dz
            d2 = dx * dx + dy * dy + dz * dz
            moved = d2 if d2 > moved
          end
          break if moved < stop
        end
        interior.each { |k| r, i = keys[k]; rows[r][i] = [xs[k], ys[k], zs[k]] }
      end

      # Largest angle between triangles sharing an edge (keys are any
      # hashable vertex keys, coord maps a key to a point).
      def tri_fold(tris, coord)
        nrm = tris.map { |t| V.norm(V.newell(t.map { |k| coord.call(k) })) }
        owners = Hash.new { |h, k| h[k] = [] }
        tris.each_with_index do |t, ti|
          3.times { |i| owners[[t[i], t[(i + 1) % 3]].sort] << ti }
        end
        worst = 0.0
        owners.each_value do |l|
          next unless l.size == 2
          a = nrm[l[0]]
          o = nrm[l[1]]
          next if V.len(a) == 0.0 || V.len(o) == 0.0
          c = [[V.dot(a, o), 1.0].min, -1.0].max
          ang = Math.acos(c) * 180.0 / Math::PI
          worst = ang if ang > worst
        end
        worst
      end

      # Three-sided patch with a cusp (two sides leaving a corner in almost
      # the same direction, typical of inner corners): filled as a Coons
      # patch collapsed at the cusp, which cannot fold.
      def cusp_fill(b, _pts, es, sel, profs, src)
        sides = patch_sides(b, es, sel, profs)
        return false unless sides.size == 3
        best = nil
        3.times do |k|
          sa = sides[(k - 1) % 3] # ends at the corner
          sb = sides[k]           # starts at the corner
          next unless sa.size == sb.size && sa.size >= 3
          p0 = @points[sb[0]]
          u1 = V.norm(V.sub(@points[sb[1]], p0))
          u2 = V.norm(V.sub(@points[sa[-2]], p0))
          ang = Math.acos([[V.dot(u1, u2), 1.0].min, -1.0].max) * 180.0 / Math::PI
          best = [ang, k] if best.nil? || ang < best[0]
        end
        return false unless best && best[0] < CUSP_DEG
        k = best[1]
        sb = sides[k]
        sc = sides[(k + 1) % 3]
        sa = sides[(k - 1) % 3].reverse
        n1 = sb.size - 1
        n2 = sc.size - 1
        p0 = @points[sb[0]]
        p1 = @points[sc[0]]
        p2 = @points[sc[-1]]
        rows = [[sb[0]] * (n2 + 1)]
        (1...n1).each do |j|
          w = j.to_f / n1
          d0 = @points[sb[j]]
          d1 = @points[sa[j]]
          # Cross section: the far side's shape, scaled to this row's width.
          ratio = V.dist(d0, d1) / [V.dist(p1, p2), 1e-12].max
          row = [sb[j]]
          (1...n2).each do |i|
            u = i.to_f / n2
            sag = V.sub(@points[sc[i]], V.lerp(p1, p2, u))
            row << new_point(V.add(V.lerp(d0, d1, u), V.mul(sag, [ratio, w].min)))
          end
          row << sa[j]
          rows << row
        end
        rows << sc
        polys = []
        n1.times do |j|
          n2.times do |i|
            polys.concat(add_poly([rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]], src))
          end
        end
        mark_soft_polys(polys, boundary_pairs(b), true)
        p0 && true
      end

      # Largest angle (degrees) between neighbouring cells of a ring grid
      # (rows of points from the boundary inward, then the apex).
      def grid_fold(rows, apex)
        m = rows[0].size
        nr = rows.size
        cells = {}
        nr.times do |r|
          m.times do |i|
            i1 = (i + 1) % m
            q = r + 1 < nr ? [rows[r][i], rows[r][i1], rows[r + 1][i1], rows[r + 1][i]] : [rows[r][i], rows[r][i1], apex]
            cells[[r, i]] = V.norm(V.newell(q))
          end
        end
        worst = 0.0
        cells.each do |(r, i), n|
          nb = [cells[[r, (i + 1) % m]], cells[[r + 1, i]]].compact
          nb.each do |o|
            next if V.len(n) == 0.0 || V.len(o) == 0.0
            c = V.dot(n, o)
            c = 1.0 if c > 1.0
            c = -1.0 if c < -1.0
            a = Math.acos(c) * 180.0 / Math::PI
            worst = a if a > worst
          end
        end
        worst
      end

      # Cubic Hermite from boundary point p (tangent t) to the apex a, where
      # it arrives tangent to the plane of normal na.
      def hermite_to_apex(p, t, a, na, s)
        l = @hermite_len * V.dist(p, a)
        d = V.sub(a, p)
        e = V.norm(V.sub(d, V.mul(na, V.dot(d, na))))
        s2 = s * s
        s3 = s2 * s
        h00 = 2 * s3 - 3 * s2 + 1
        h10 = s3 - 2 * s2 + s
        h01 = -2 * s3 + 3 * s2
        h11 = s3 - s2
        V.add(V.add(V.mul(p, h00), V.mul(t, h10 * l)), V.add(V.mul(a, h01), V.mul(e, h11 * l)))
      end

      # Sharp corner: every rounded edge is extended along its edge until it
      # meets the extension of its neighbours. Ridges are the exact
      # intersections of the extended strips and end at a common apex.
      # Returns false when the configuration is unsuitable.
      def sharp_fill(es, dirs, profs, c, src)
        n = es.size
        nseg = @segs
        return false unless profs.all? { |pr| pr && pr.size == nseg + 1 }
        ppts = profs.map { |ids| ids.map { |id| @points[id] } }
        eps = @offset * 1e-6

        # For every ray of every strip: distance to the neighbour strips.
        info = []
        n.times do |i|
          ip = (i - 1) % n
          inx = (i + 1) % n
          srcs = []
          lams = []
          (0..nseg).each do |j|
            p = ppts[i][j]
            lp = j == 0 ? 0.0 : prism_hit(p, dirs[i], ppts[ip], dirs[ip])
            ln = j == nseg ? 0.0 : prism_hit(p, dirs[i], ppts[inx], dirs[inx])
            return false if lp.nil? && ln.nil?
            if ln.nil? || (lp && lp < ln - eps)
              srcs << :prev
            elsif lp.nil? || ln < lp - eps
              srcs << :next
            else
              srcs << :tie
            end
            lams << [lp, ln]
          end
          # Expected pattern: prev ... prev [tie] next ... next
          j0 = srcs.rindex { |x| x != :next }
          j1 = srcs.index { |x| x != :prev }
          return false unless j0 && j1
          return false unless (0..j0).all? { |j| srcs[j] != :next } && (j1..nseg).all? { |j| srcs[j] != :prev }
          tie = srcs.index(:tie)
          return false if tie && srcs.count(:tie) > 1
          return false unless tie ? (j0 == tie && j1 == tie) : j1 == j0 + 1
          if tie
            apex = V.sub(ppts[i][tie], V.mul(dirs[i], lams[tie][0]))
          else
            lp0, ln0 = lams[j0]
            lp1, ln1 = lams[j1]
            x0 = V.sub(ppts[i][j0], V.mul(dirs[i], lp0))
            x1 = V.sub(ppts[i][j1], V.mul(dirs[i], ln1))
            if ln0 && lp1
              f0 = lp0 - ln0
              f1 = lp1 - ln1
              t = (f0 - f1).abs > 1e-12 ? f0 / (f0 - f1) : 0.5
              t = [[t, 0.0].max, 1.0].min
            else
              t = 0.5
            end
            apex = V.lerp(x0, x1, t)
          end
          info << { :srcs => srcs, :lams => lams, :apex => apex, :tie => tie }
        end
        s_coord = V.avg(info.map { |h| h[:apex] })

        # Ridge between strip i and i+1: ray ends of both strips, merged and
        # sorted from the shared corner point m_i to the apex.
        ridge_pts = []
        n.times do |i|
          inx = (i + 1) % n
          mi = @points[c[i][0]]
          items = []
          (0..nseg).each do |j|
            next unless info[i][:srcs][j] == :next
            items << [[i, j], V.sub(ppts[i][j], V.mul(dirs[i], info[i][:lams][j][1]))]
          end
          (0..nseg).each do |j|
            next unless info[inx][:srcs][j] == :prev
            items << [[inx, j], V.sub(ppts[inx][j], V.mul(dirs[inx], info[inx][:lams][j][0]))]
          end
          items.sort_by! { |_k, x| V.dist(x, mi) }
          ridge_pts << items
        end

        # Ridge points closer than a fraction of a profile segment are merged
        # (avoids sliver triangles).
        seg_len = ppts.map { |q| (0...nseg).map { |j| V.dist(q[j], q[j + 1]) }.inject(:+) / nseg }.min
        merge_d = [seg_len * 0.2, eps * 10].max
        s_id = new_point(s_coord)
        ray_end = {}
        ridges_ids = []
        n.times do |i|
          chain = [c[i][0]]
          last = @points[c[i][0]]
          ridge_pts[i].each do |key, x|
            if V.dist(x, last) <= merge_d
              ray_end[key] = chain.last
              next
            end
            if V.dist(x, s_coord) <= merge_d
              ray_end[key] = s_id
              next
            end
            id = new_point(x)
            chain << id
            ray_end[key] = id
            last = x
          end
          chain << s_id
          ridges_ids << chain
        end

        polys = []
        ridges = {}
        n.times do |i|
          pids = profs[i]
          vv = ridges_ids[(i - 1) % n] + ridges_ids[i][0...-1].reverse
          (0...vv.size - 1).each { |j| ridges[ekey(vv[j], vv[j + 1])] = true }
          pos = {}
          vv.each_with_index { |id, k| pos[id] = k }
          idx = (0..nseg).map do |j|
            e = info[i][:srcs][j] == :tie ? s_id : ray_end[[i, j]]
            pos[e]
          end
          return false if idx.any?(&:nil?)
          return false unless (0...nseg).all? { |j| idx[j] <= idx[j + 1] }
          nseg.times do |j|
            a = idx[j]
            bnd = idx[j + 1]
            if bnd == a
              polys.concat(add_poly([pids[j], pids[j + 1], vv[a]], src))
            elsif bnd == a + 1
              polys.concat(add_poly([pids[j], pids[j + 1], vv[bnd], vv[a]], src))
            else
              polys.concat(add_poly([pids[j], pids[j + 1], vv[bnd]], src))
              (a...bnd).each { |k| polys.concat(add_poly([pids[j], vv[k + 1], vv[k]], src)) }
            end
          end
        end
        boundary = {}
        n.times { |i| (0...profs[i].size - 1).each { |j| boundary[ekey(profs[i][j], profs[i][j + 1])] = true } }
        mark_soft_polys(polys, boundary, true, ridges)
        true
      end

      # Distance along the ray p - a * t (t >= 0) to the extension of a strip
      # (the profile polyline qs swept along -b). nil when there is no hit.
      def prism_hit(p, a, qs, b)
        ref = b[0].abs < 0.9 ? [1.0, 0.0, 0.0] : [0.0, 1.0, 0.0]
        e1 = V.norm(V.cross(b, ref))
        e2 = V.cross(b, e1)
        pr = lambda { |x| [V.dot(x, e1), V.dot(x, e2)] }
        p2 = pr.call(p)
        d2 = pr.call(V.mul(a, -1.0))
        return nil if d2[0].abs + d2[1].abs < 1e-12
        tol = @offset * 1e-6
        best = nil
        (0...qs.size - 1).each do |k|
          q0 = pr.call(qs[k])
          q1 = pr.call(qs[k + 1])
          sx = q1[0] - q0[0]
          sy = q1[1] - q0[1]
          det = -d2[0] * sy + sx * d2[1]
          next if det.abs < 1e-14
          rx = q0[0] - p2[0]
          ry = q0[1] - p2[1]
          lam = (-rx * sy + sx * ry) / det
          mu = (d2[0] * ry - d2[1] * rx) / det
          next if mu < -1e-6 || mu > 1.0 + 1e-6 || lam < -tol
          x = V.sub(p, V.mul(a, lam))
          q = V.lerp(qs[k], qs[k + 1], mu)
          next if V.dot(V.sub(q, x), b) < -tol
          lam = 0.0 if lam < 0.0
          best = lam if best.nil? || lam < best
        end
        best
      end

      # Adds a polygon (dropping duplicates); non-planar quads are split in
      # two triangles with a soft diagonal. Returns the polygons added.
      def add_poly(ids, src)
        ids = dedupe_cyclic(ids)
        return [] if ids.size < 3
        pts = ids.map { |i| @points[i] }
        return [] if V.len(V.newell(pts)) * 0.5 < @area_tol
        unless planar?(pts, @ptol)
          if ids.size == 4
            d02 = V.dist(pts[0], pts[2])
            d13 = V.dist(pts[1], pts[3])
            if d02 <= d13
              tris = [[ids[0], ids[1], ids[2]], [ids[0], ids[2], ids[3]]]
              @soft[ekey(ids[0], ids[2])] = true
              @diagonals[ekey(ids[0], ids[2])] = true
            else
              tris = [[ids[0], ids[1], ids[3]], [ids[1], ids[2], ids[3]]]
              @soft[ekey(ids[1], ids[3])] = true
              @diagonals[ekey(ids[1], ids[3])] = true
            end
          else
            cid = new_point(V.avg(pts))
            n = ids.size
            tris = (0...n).map { |i| [ids[i], ids[(i + 1) % n], cid] }
            n.times { |i| @soft[ekey(ids[i], cid)] = true; @diagonals[ekey(ids[i], cid)] = true }
          end
          out = []
          tris.each do |t|
            tp = t.map { |i| @points[i] }
            next if V.len(V.newell(tp)) * 0.5 < @area_tol
            @new_polys << { :ids => t, :src => src, :kind => @cur_kind }
            out << t
          end
          return out
        end
        @new_polys << { :ids => ids, :src => src, :kind => @cur_kind }
        [ids]
      end

      # ------------------------------------------------------------------
      # Strips, checks, face loops, orientation
      # ------------------------------------------------------------------

      def oriented_profile(k, v, fa)
        ids, from = @end_prof[[k, v]]
        from == fa ? ids : ids.reverse
      end

      def check_offsets
        @sel.each_key do |k|
          a, b = k
          fa = @edge_faces[k][0]
          pa = oriented_profile(k, a, fa)
          pb = oriented_profile(k, b, fa)
          org = @points[a]
          dir = V.norm(V.sub(@points[b], org))
          proj = lambda { |id| V.dot(V.sub(@points[id], org), dir) }
          na = pa.size
          nb = pb.size
          [na, nb].max.times do |j|
            ia = pa[[j, na - 1].min]
            ib = pb[[j, nb - 1].min]
            next unless proj.call(ia) > proj.call(ib) + @tol
            @edge_faces[k].each do |f|
              blame_face_corner(f, a)
              blame_face_corner(f, b)
            end
            break
          end
        end
        ends = Hash.new { |h, k| h[k] = [] }
        @trim.each { |(k, v), t| ends[k] << [v, t] }
        ends.each do |k, vts|
          next if vts.size < 2
          len = V.dist(@points[k[0]], @points[k[1]])
          next unless vts.inject(0.0) { |acc, (_v, t)| acc + t } > len - @tol
          vts.each do |v, _t|
            @viol[v] = true
            (@trim_src[[k, v]] || []).each { |e| blame_edge(e) }
          end
        end
      end

      # Rebuilt face loops must keep their orientation and must not cross
      # themselves (offset lines crossing in narrow faces).
      def check_face_loops
        @face_loops.each do |fi, loops|
          nrm = V.norm(@faces[fi][:normal])
          ax = nrm.map(&:abs)
          drop = ax.index(ax.max)
          keep = [0, 1, 2] - [drop]
          loops.each_with_index do |lp, li|
            orig = @faces[fi][:loops][li]
            p2 = lp.map { |i| @points[i].values_at(*keep) }
            o2 = orig.map { |i| @points[i].values_at(*keep) }
            if area2(p2) * area2(o2) <= 0.0
              orig.each { |u| blame_face_corner(fi, u) if @corner.key?([fi, u]) }
              next
            end
            cross = self_crossing(p2)
            next unless cross
            blame_crossing(fi, [[li, cross[0]], [li, cross[1]]], [li])
          end
          check_loop_pairs(fi, loops, keep) if loops.size > 1
        end
      end

      # The loops of a face with holes must not cross each other, and every
      # hole must stay inside the outer loop. (A hole whose edges grow
      # outward while the outer loop shrinks can end up around the outer
      # loop without any loop crossing itself: the face turns inside out.)
      def check_loop_pairs(fi, loops, keep)
        p2 = loops.map { |lp| lp.map { |i| @points[i].values_at(*keep) } }
        loops.size.times do |a|
          ((a + 1)...loops.size).each do |b|
            # Points on the wrong side: of the hole outside the outer loop,
            # of the outer loop inside the hole (or of a hole inside another).
            wrong = []
            if a == 0
              p2[b].each_with_index { |q, k| wrong << [b, k] unless inside?(q, p2[0]) }
              p2[0].each_with_index { |q, k| wrong << [0, k] if inside?(q, p2[b]) }
            else
              p2[b].each_with_index { |q, k| wrong << [b, k] if inside?(q, p2[a]) }
              p2[a].each_with_index { |q, k| wrong << [a, k] if inside?(q, p2[b]) }
            end
            hit = loops_crossing(p2[a], p2[b])
            next if wrong.empty? && !hit
            blamed = false
            # Their corners: the edges there pushed them over.
            wrong.each do |li, k|
              u = @loop_origin[[fi, li]][k]
              blamed = true if @corner.key?([fi, u]) && blame_face_corner(fi, u)
            end
            # Crossing segments along selected edges: those edges too.
            blamed = true if hit && blame_crossing(fi, [[a, hit[0]], [b, hit[1]]], [a, b])
            blame_loops(fi, [a, b]) unless blamed
          end
        end
      end

      # Two crossing segments of rebuilt loops of face fi ([loop, index]
      # each). A segment running along a selected edge (its ends come from
      # that edge's two corners) blames that edge: its offset moved it too
      # far. A segment along an unselected edge is not to blame (it stays
      # in place). Any other segment (inside a corner) blames the face's
      # edges at that corner. If nothing is blamed, all corners of the
      # loops are.
      def blame_crossing(fi, segs, lis)
        blamed = false
        segs.each do |li, k|
          origin = @loop_origin[[fi, li]]
          u = origin[k]
          w = origin[(k + 1) % origin.size]
          if u != w
            e = ekey(u, w)
            next unless @sel.key?(e)
            @viol[u] = true
            @viol[w] = true
            @viol_edges[e] = true
            blamed = true
          elsif @corner.key?([fi, u])
            blamed = true if blame_face_corner(fi, u)
          end
        end
        blame_loops(fi, lis) unless blamed
        true
      end

      # Marks all corners of the given loops of face fi.
      def blame_loops(fi, lis)
        lis.each do |li|
          @faces[fi][:loops][li].each { |u| blame_face_corner(fi, u) if @corner.key?([fi, u]) }
        end
      end

      # Indices of a crossing pair of segments of two closed 2D polygons, or nil.
      def loops_crossing(p, q)
        return nil if p.size * q.size > 360_000
        eps = (@scale * 1e-9)**2
        orient = lambda { |a, b, c| (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) }
        qb = (0...q.size).map do |j|
          c = q[j]
          d = q[(j + 1) % q.size]
          [[c[0], d[0]].min, [c[0], d[0]].max, [c[1], d[1]].min, [c[1], d[1]].max]
        end
        p.size.times do |i|
          a = p[i]
          b = p[(i + 1) % p.size]
          x0, x1 = [a[0], b[0]].minmax
          y0, y1 = [a[1], b[1]].minmax
          q.size.times do |j|
            bb = qb[j]
            next if bb[1] < x0 || bb[0] > x1 || bb[3] < y0 || bb[2] > y1
            c = q[j]
            d = q[(j + 1) % q.size]
            d1 = orient.call(c, d, a)
            d2 = orient.call(c, d, b)
            next unless d1 * d2 < -eps
            d3 = orient.call(a, b, c)
            d4 = orient.call(a, b, d)
            return [i, j] if d3 * d4 < -eps
          end
        end
        nil
      end

      # Point in polygon (2D, even-odd rule).
      def inside?(pt, poly)
        x, y = pt
        res = false
        n = poly.size
        n.times do |i|
          a = poly[i]
          b = poly[(i + 1) % n]
          next unless (a[1] > y) != (b[1] > y)
          res = !res if x < a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
        end
        res
      end

      def blame_edge(k)
        @viol_edges[k] = true if k && @sel.key?(k)
      end

      # Corner u of face fi does not fit: blame the selected edges of that
      # face at u (their offsets shape the face there), or all selected
      # edges at u if the face has none.
      def blame_face_corner(fi, u)
        @viol[u] = true
        found = false
        @faces[fi][:loops].each do |lp|
          n = lp.size
          i = lp.index(u)
          next unless i
          [ekey(lp[(i - 1) % n], u), ekey(u, lp[(i + 1) % n])].each do |k|
            next unless @sel.key?(k)
            @viol_edges[k] = true
            found = true
          end
        end
        @sel_at[u].each { |k| @viol_edges[k] = true } unless found
        found || !@sel_at[u].empty?
      end

      def area2(p)
        a = 0.0
        n = p.size
        n.times { |i| a += p[i][0] * p[(i + 1) % n][1] - p[(i + 1) % n][0] * p[i][1] }
        a
      end

      # Indices of two crossing segments of a closed 2D polygon, or nil.
      def self_crossing(p)
        n = p.size
        return nil if n < 4 || n > 600
        eps = (@scale * 1e-9)**2
        orient = lambda { |a, b, c| (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) }
        n.times do |i|
          a = p[i]
          b = p[(i + 1) % n]
          ((i + 2)...n).each do |j|
            next if i == 0 && j == n - 1
            c = p[j]
            d = p[(j + 1) % n]
            d1 = orient.call(c, d, a)
            d2 = orient.call(c, d, b)
            next unless d1 * d2 < -eps
            d3 = orient.call(a, b, c)
            d4 = orient.call(a, b, d)
            return [i, j] if d3 * d4 < -eps
          end
        end
        nil
      end

      def build_strips
        @cur_kind = :strip
        @sel.each_key do |k|
          a, b = k
          fa = @edge_faces[k][0]
          pa = oriented_profile(k, a, fa)
          pb = oriented_profile(k, b, fa)
          nseg = [pa.size, pb.size].max - 1
          pa = [pa[0]] * (nseg + 1) if pa.size == 1
          pb = [pb[0]] * (nseg + 1) if pb.size == 1
          nseg.times { |j| add_poly([pa[j], pa[j + 1], pb[j + 1], pb[j]], fa) }
          (1...nseg).each { |j| @soft[ekey(pa[j], pb[j])] = true }
        end
      end

      def build_face_loops
        @face_loops = {}
        touched = {}
        @corner.each_key { |fi, _v| touched[fi] = true }
        # Corner each point of a rebuilt loop comes from (for error reports).
        @loop_origin = {}
        touched.keys.sort.each do |fi|
          changed = false
          loops = @faces[fi][:loops].each_with_index.map do |lp, li|
            out = []
            origin = []
            nl = lp.size
            lp.each_with_index do |u, i|
              cr = @corner[[fi, u]]
              if cr
                ids, first_edge = cr
                seq = ekey(lp[(i - 1) % nl], u) == first_edge ? ids : ids.reverse
                seq.each { |x| next if out.last == x; out << x; origin << u }
              else
                next if out.last == u
                out << u
                origin << u
              end
            end
            while out.size > 1 && out.last == out.first
              out.pop
              origin.pop
            end
            @loop_origin[[fi, li]] = origin
            changed = true if out != lp
            out
          end
          @face_loops[fi] = loops if changed
        end
      end

      def each_pair(ids)
        k = ids.size
        k.times { |i| yield ids[i], ids[(i + 1) % k] }
      end

      # Orients the new polygons consistently with the rebuilt faces (each
      # shared edge must be used in opposite directions).
      def orient_polys
        dir = {}
        @face_loops.each_value { |loops| loops.each { |lp| each_pair(lp) { |a, b| dir[[a, b]] = true } } }
        users = Hash.new { |h, k| h[k] = [] }
        @new_polys.each_with_index { |poly, pi| each_pair(poly[:ids]) { |a, b| users[ekey(a, b)] << pi } }
        done = {}
        queue = []
        # Seed: polygons touching the rebuilt faces.
        @new_polys.each_with_index do |poly, pi|
          queue << pi if touches?(poly[:ids], dir)
        end
        loop do
          until queue.empty?
            pi = queue.shift
            next if done[pi]
            ids = @new_polys[pi][:ids]
            decision = nil
            each_pair(ids) do |a, b|
              if dir[[a, b]]
                decision = :flip
                break
              elsif dir[[b, a]]
                decision = :keep
                break
              end
            end
            next unless decision
            ids.reverse! if decision == :flip
            done[pi] = true
            each_pair(ids) do |a, b|
              dir[[a, b]] = true
              users[ekey(a, b)].each { |o| queue << o unless done[o] }
            end
          end
          rest = (0...@new_polys.size).find { |pi| !done[pi] }
          break unless rest
          # Disconnected piece: keep its orientation as generated.
          done[rest] = true
          each_pair(@new_polys[rest][:ids]) do |a, b|
            dir[[a, b]] = true
            users[ekey(a, b)].each { |o| queue << o unless done[o] }
          end
        end
      end

      def touches?(ids, dir)
        found = false
        each_pair(ids) { |a, b| found = true if dir[[a, b]] || dir[[b, a]] }
        found
      end
    end
  end
end
