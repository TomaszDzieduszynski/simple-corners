# Simple Corners - rebuilds the sharp edges and corners under a rounded or
# bevelled surface, from the geometry alone (pure Ruby, no SketchUp API).
#
# Works on any network of fillets, chamfers and corner patches, whatever
# made them. The faces around the surface (its neighbours) are extended
# until they meet again:
#   1. Each face of the surface is given to the neighbour it came from:
#      grown inwards from the outline, every face goes to the reachable
#      neighbour whose direction (normal) is closest to its own.
#   2. Where the areas of two neighbours touch, their planes meet in a sharp
#      edge; where three or more touch, in a sharp corner.
#   3. Each neighbour gets a new outline: its old outline plus its area of
#      the surface, with the corners replaced by those points.
# Everything is checked (flat, not crossing itself, not flipped, closed)
# before anything changes; anything unclear raises Error.
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

module SimpleCorners
  module Resharpen
    class Error < StandardError; end

    V = Core::V

    # Most faces around one point that is split back into separate corners.
    MAX_SPLIT = 8

    # points: [[x, y, z]]; faces: [{ :loops => [[point ids]] (outer first,
    # counter-clockwise around the normal; holes clockwise), :normal => [x,
    # y, z], :soft => ids of faces across its soft edges (-1: a face not in
    # the list) }]: the surface and every face touching it (more is fine).
    # region: ids of the surface's faces. open_edges: point id pairs of
    # edges with only one face in the model.
    # Returns { face id => [loops of [x, y, z]] (outer first) } for every
    # face to rebuild; the region's faces are removed.
    # min_dist: points closer than this are one point (SketchUp merges
    # points closer than its 0.001 inch tolerance).
    def self.solve(points, faces, region, open_edges = [], min_dist = nil)
      first = nil
      WEIGHTS.each do |w|
        begin
          return Solver.new(points, faces, region, open_edges, min_dist, w).solve
        rescue Error => e
          first ||= e
        end
      end
      raise first
    end

    # Ways of telling which face a piece of the surface came from, tried in
    # turn: by direction only, then also by distance (better on strongly
    # leaning faces). Every result is fully checked.
    WEIGHTS = [0.0, 0.3, 3.0].freeze

    # Minimal binary heap of [cost, sequence, ...] arrays.
    class Heap
      def initialize
        @a = []
      end

      def empty?
        @a.empty?
      end

      def push(x)
        @a << x
        i = @a.size - 1
        while i > 0
          j = (i - 1) / 2
          break unless less(i, j)
          @a[i], @a[j] = @a[j], @a[i]
          i = j
        end
      end

      def pop
        top = @a[0]
        last = @a.pop
        return top if @a.empty?
        @a[0] = last
        i = 0
        loop do
          l = 2 * i + 1
          r = l + 1
          m = i
          m = l if l < @a.size && less(l, m)
          m = r if r < @a.size && less(r, m)
          break if m == i
          @a[i], @a[m] = @a[m], @a[i]
          i = m
        end
        top
      end

      def less(i, j)
        a = @a[i]
        b = @a[j]
        a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
      end
    end

    class Solver
      def initialize(points, faces, region, open_edges, min_dist = nil, weight = 0.0)
        @weight = weight
        @pts = points
        @faces = faces
        @region = region.uniq
        @in = {}
        @region.each { |f| @in[f] = true }
        @open = {}
        open_edges.each { |a, b| @open[a < b ? [a, b] : [b, a]] = true }
        @edge_faces = Hash.new { |h, k| h[k] = [] }
        @vert_faces = Hash.new { |h, k| h[k] = [] }
        @face_edges = []
        @dir = [] # per face: {edge key => true if traversed low -> high}
        faces.each_with_index do |f, fi|
          keys = []
          dirs = {}
          f[:loops].each do |lp|
            lp.each_with_index do |a, i|
              b = lp[(i + 1) % lp.size]
              next if a == b
              k = a < b ? [a, b] : [b, a]
              keys << k
              dirs[k] = a < b
              @edge_faces[k] << fi
              @vert_faces[a] << fi unless @vert_faces[a].include?(fi)
            end
          end
          @face_edges << keys
          @dir << dirs
        end
        @planes = faces.map do |f|
          n = V.norm(f[:normal])
          [n, V.dot(n, points[f[:loops][0][0]])]
        end
        ids = @region.flat_map { |fi| faces[fi][:loops].flatten }.uniq
        rp = ids.map { |i| points[i] }
        rp = [[0.0, 0.0, 0.0]] if rp.empty?
        lo = (0..2).map { |c| rp.map { |q| q[c] }.min }
        hi = (0..2).map { |c| rp.map { |q| q[c] }.max }
        @size = V.dist(lo, hi)
        @tol = 1e-9 * (1 + @size)
        @plane_tol = 1e-6 * (1 + @size)
        @merge = [min_dist || 1e-7 * (1 + @size), @tol].max
      end

      def solve
        raise Error, 'select the rounded or bevelled surface first.' if @region.empty?
        @rv = {}
        @region.each { |fi| @faces[fi][:loops].flatten.each { |v| @rv[v] = true } }
        find_neighbours
        check_soft
        orient
        label_cells
        @out = @rv.keys.flat_map { |v| @vert_faces[v] }.uniq.reject { |fi| @in[fi] }
        @meet = {}
        @junction = {}
        result = {}
        @out.each { |p| result[p] = face_loops(p) }
        snap(result)
        check_closed(result)
        result
      end

      private

      def key(a, b)
        a < b ? [a, b] : [b, a]
      end

      def find_neighbours
        @bound = []
        @nb = {}
        @region.each do |fi|
          @face_edges[fi].each do |k|
            fs = @edge_faces[k]
            raise Error, 'the surface has an open edge (every edge must border two faces).' if fs.size < 2
            raise Error, 'the surface has an edge shared by more than two faces.' if fs.size > 2
            o = fs[0] == fi ? fs[1] : fs[0]
            next if @in[o]
            @bound << [fi, o]
            @nb[o] = true
          end
        end
        raise Error, 'the selection has no outline (select only the rounded or bevelled faces).' if @nb.empty?
      end

      # A neighbour that continues smoothly into faces outside the selection
      # is part of a larger smooth surface (only part of it is selected).
      def check_soft
        @nb.each_key do |n|
          (@faces[n][:soft] || []).each do |p|
            next if p >= 0 && (@in[p] || @nb[p])
            raise Error, 'only part of a smooth surface is selected (select the whole rounded surface).'
          end
        end
      end

      # Face directions made consistent across shared edges (reversed faces
      # in the model must not confuse the comparison of directions).
      def orient
        @flip = {}
        local = (0...@faces.size).to_a
        lset = {}
        local.each { |f| lset[f] = true }
        local.each do |s|
          next if @flip.key?(s)
          @flip[s] = false
          todo = [s]
          until todo.empty?
            f = todo.pop
            @face_edges[f].each do |k|
              @edge_faces[k].each do |g|
                next if g == f || !lset[g] || @flip.key?(g)
                same = @dir[f][k] == @dir[g][k] # same direction: opposite facing
                @flip[g] = same ? !@flip[f] : @flip[f]
                todo << g
              end
            end
          end
        end
      end

      def normal(f)
        n = @planes[f][0]
        @flip[f] ? V.mul(n, -1.0) : n
      end

      # How badly face f fits the plane of face lab: the difference of their
      # directions, plus (weight > 0) its distance from that plane.
      def cost(f, lab)
        c = 1.0 - V.dot(normal(f), normal(lab))
        c += @weight * dist_max(f, lab) / face_size(f) if @weight > 0
        c
      end

      # Largest distance of the corners of face f from the plane of face l.
      def dist_max(f, l)
        n, d = @planes[l]
        @faces[f][:loops][0].map { |v| (V.dot(n, @pts[v]) - d).abs }.max
      end

      def face_size(f)
        @fsize ||= {}
        @fsize[f] ||= begin
          ps = @faces[f][:loops][0].map { |v| @pts[v] }
          ps.map { |a| ps.map { |b| V.dist(a, b) }.max }.max + @tol
        end
      end

      def label_cells
        @label = {}
        heap = Heap.new
        seq = 0
        @bound.each { |fi, n| heap.push([cost(fi, n), seq += 1, fi, n]) }
        until heap.empty?
          _c, _s, fi, lab = heap.pop
          next if @label.key?(fi)
          @label[fi] = lab
          @face_edges[fi].each do |k|
            @edge_faces[k].each do |g|
              next if !@in[g] || @label.key?(g)
              heap.push([cost(g, lab), seq += 1, g, lab])
            end
          end
        end
        refine_labels
        @cells = {}
        @region.each { |fi| (@cells[@label[fi]] ||= []) << fi }
      end

      # The first neighbour to reach a face takes it, even when a neighbour
      # it fits better arrives just after. Faces move to a touching area
      # they fit clearly better, until nothing changes; then pieces cut off
      # from their own face join the best touching area that is connected.
      def refine_labels
        30.times do
          changed = false
          @region.each do |f|
            cur = @label[f]
            best = cur
            bc = cost(f, cur)
            adjacent_labels(f).each do |l|
              c = cost(f, l)
              if c < bc - 1e-9
                best = l
                bc = c
              end
            end
            next if best == cur
            @label[f] = best
            changed = true
          end
          break unless changed
        end
        reconnect_cells
      end

      def adjacent_labels(f)
        out = []
        @face_edges[f].each do |k|
          @edge_faces[k].each { |g| out << lab(g) unless g == f }
        end
        out.uniq
      end

      def reconnect_cells
        (@region.size + 1).times do
          ok = {}
          by = Hash.new { |h, l| h[l] = [] }
          @region.each { |f| by[@label[f]] << f }
          by.each do |l, fs|
            fset = {}
            fs.each { |f| fset[f] = true }
            todo = []
            fs.each do |f|
              touches = @face_edges[f].any? { |k| @edge_faces[k].include?(l) }
              if touches
                ok[f] = true
                todo << f
              end
            end
            until todo.empty?
              f = todo.pop
              @face_edges[f].each do |k|
                @edge_faces[k].each do |g|
                  next unless fset[g] && !ok[g]
                  ok[g] = true
                  todo << g
                end
              end
            end
          end
          stray = @region.reject { |f| ok[f] }
          return if stray.empty?
          moved = false
          stray.each do |f|
            cands = []
            @face_edges[f].each do |k|
              @edge_faces[k].each do |g|
                next if g == f
                cands << lab(g) if !@in[g] || ok[g]
              end
            end
            cands.uniq!
            next if cands.empty?
            @label[f] = cands.min_by { |l| cost(f, l) }
            ok[f] = true
            moved = true
          end
          raise Error, 'not recognised (unclear surface).' unless moved
        end
      end

      def lab(f)
        @in[f] ? @label[f] : f
      end

      def across(k, u)
        fs = @edge_faces[k].reject { |f| u[f] }
        return :ext if fs.empty?
        return :multi if fs.size > 1
        lab(fs[0])
      end

      # New loops of face p (outer first).
      def face_loops(p)
        u = { p => true }
        (@cells[p] || []).each { |f| u[f] = true }
        cnt = Hash.new(0)
        u.each_key { |f| @face_edges[f].each { |k| cnt[k] += 1 } }
        bedges = cnt.keys.select { |k| cnt[k] == 1 }
        at = Hash.new { |h, v| h[v] = [] }
        bedges.each { |k| at[k[0]] << k; at[k[1]] << k }
        at.each_value do |l|
          raise Error, 'not recognised (parts of the surface touch at a point).' if l.size != 2
        end
        used = {}
        loops = []
        bedges.each do |k0|
          next if used[k0]
          vs = []
          qs = []
          k = k0
          v = k0[0]
          loop do
            used[k] = true
            vs << v
            qs << across(k, u)
            w = k[0] == v ? k[1] : k[0]
            break if w == vs[0]
            v = w
            k = (at[w] - [k])[0]
            raise Error, 'not recognised (outline of a face is not closed).' if k.nil? || used[k]
          end
          loops << [vs, qs]
        end

        n = @planes[p][0]
        res = loops.map do |vs, qs|
          out = []
          vs.each_with_index do |v, i|
            qp = qs[i - 1]
            qn = qs[i]
            if !@rv[v]
              out << @pts[v]
            elsif qp != qn
              out.concat(junction(v, p, qp, qn))
            end
          end
          out = dedupe(out)
          raise Error, 'not recognised (a rebuilt face would have no area).' if out.size < 3
          old = vs.map { |v| @pts[v] }
          so = V.dot(V.newell(old), n)
          sn = V.dot(V.newell(out), n)
          if sn.abs < @tol * @size || so * sn <= 0
            raise Error, 'not recognised (a rebuilt face would be turned inside out).'
          end
          [out, so.abs]
        end
        res.sort_by! { |_lp, a| -a }
        lps = res.map(&:first)
        check_face(p, lps)
        lps
      end

      def dedupe(pts)
        out = []
        pts.each { |q| out << q if out.empty? || V.dist(out.last, q) > @merge }
        out.pop while out.size > 1 && V.dist(out.last, out.first) <= @merge
        out
      end

      # Corner point(s) of face p at region vertex v between the areas of
      # qp and qn.
      def junction(v, p, qp, qn)
        if qp.is_a?(Symbol) || qn.is_a?(Symbol)
          raise Error, 'not recognised (the surface outline is open or shared by several faces).'
        end
        j = (@junction[v] ||= resolve(v))
        return [j[:point]] if j[:point]
        tris = j[:tris].select { |labs, _q| labs.include?(p) }
        raise Error, 'not recognised (unclear corner).' if tris.empty?
        return [tris[0][1]] if tris.size == 1
        # the corners of p in order from the side of qp to the side of qn
        cyc = j[:cycle]
        k = cyc.size
        i = cyc.index(p)
        dir = cyc[(i + 1) % k] == qp ? 1 : -1
        off = lambda { |x| ((cyc.index(x) - i) * dir) % k }
        tris.sort_by { |labs, _q| (labs - [p]).map { |x| off.call(x) }.min }.map { |_l, q| q }
      end

      def resolve(v)
        labs = @vert_faces[v].map { |f| lab(f) }.uniq
        k = labs.size
        raise Error, 'not recognised (unclear corner).' if k < 3
        pos = @pts[v]
        if k == 3
          x = meet(labs)
          raise Error, 'not recognised (faces around a corner are parallel).' unless x
          near!(x, pos)
          return { :point => x }
        end
        x = least_squares(labs)
        if x && labs.all? { |l| (V.dot(@planes[l][0], x) - @planes[l][1]).abs <= @plane_tol }
          near!(x, pos)
          return { :point => x }
        end
        raise Error, "not recognised (#{k} faces meet near one corner)." if k > MAX_SPLIT
        cyc = cycle(v)
        raise Error, 'not recognised (unclear corner).' unless cyc && cyc.size == k && cyc.uniq.size == k
        # Several corners merged into one point (the edges between them were
        # rounded away): split it back into corners of three faces each, the
        # most compact way.
        best = nil
        triangulations((0...k).to_a).each do |tris|
          labs = tris.map { |t| t.map { |i| cyc[i] } }
          pts = labs.map { |t| meet(t) }
          next if pts.any?(&:nil?)
          dist = pts.inject(0.0) { |s, q| s + V.dist(q, pos) }
          best = [labs.zip(pts), dist] if best.nil? || dist < best[1]
        end
        raise Error, 'not recognised (faces around a corner are parallel).' unless best
        best[0].each { |_t, q| near!(q, pos) }
        { :tris => best[0], :cycle => cyc }
      end

      # All triangulations of a convex polygon given as a list of corners.
      def triangulations(poly)
        return [[]] if poly.size < 3
        return [[poly]] if poly.size == 3
        a = poly[0]
        b = poly[-1]
        res = []
        (1...poly.size - 1).each do |m|
          c = poly[m]
          left = triangulations(poly[0..m])
          right = triangulations(poly[m..-1])
          left.each { |l| right.each { |r| res << (l + r + [[a, c, b]]) } }
        end
        res
      end

      def near!(x, pos)
        return if V.dist(pos, x) <= 2.0 * @size + @tol
        raise Error, 'not recognised (the sharp corner would be far from the surface).'
      end

      # Labels around vertex v in order, repeated neighbours merged.
      def cycle(v)
        fs = @vert_faces[v]
        vedges = lambda { |f| @face_edges[f].select { |k| k.include?(v) } }
        f0 = fs[0]
        e = vedges.call(f0)[0]
        f = f0
        order = []
        (fs.size + 1).times do
          order << lab(f)
          g = (@edge_faces[e] - [f])
          return nil unless g.size == 1
          f = g[0]
          break if f == f0
          es = vedges.call(f) - [e]
          return nil unless es.size == 1
          e = es[0]
        end
        return nil unless f == f0
        out = []
        order.each { |l| out << l if out.empty? || out.last != l }
        out.pop while out.size > 1 && out.last == out.first
        out
      end

      # Point where the planes of three faces meet (same point for the same
      # three faces wherever asked). Two faces in one plane: the line of the
      # original edge between them meets the third plane.
      def meet(labs)
        k = labs.sort
        return @meet[k] if @meet.key?(k)
        @meet[k] = meet3(k)
      end

      def meet3(labs)
        n1, d1 = @planes[labs[0]]
        n2, d2 = @planes[labs[1]]
        n3, d3 = @planes[labs[2]]
        det = V.dot(n1, V.cross(n2, n3))
        if det.abs > 1e-4
          x = V.add(V.add(V.mul(V.cross(n2, n3), d1), V.mul(V.cross(n3, n1), d2)), V.mul(V.cross(n1, n2), d3))
          return V.mul(x, 1.0 / det)
        end
        labs.combination(2).each do |a, b|
          next unless coplanar?(a, b)
          c = (labs - [a, b])[0]
          line = dividing_line(a, b)
          next unless line
          o, dir = line
          nc, dc = @planes[c]
          den = V.dot(nc, dir)
          next if den.abs < 1e-4
          return V.add(o, V.mul(dir, (dc - V.dot(nc, o)) / den))
        end
        nil
      end

      def coplanar?(a, b)
        na, da = @planes[a]
        nb, db = @planes[b]
        dot = V.dot(na, nb)
        (dot > 1 - 1e-9 && (da - db).abs <= @plane_tol) || (dot < -1 + 1e-9 && (da + db).abs <= @plane_tol)
      end

      # The edge between two faces in the same plane (outside the surface).
      def dividing_line(a, b)
        @face_edges[a].each do |k|
          fs = @edge_faces[k]
          next unless fs.size == 2 && fs.include?(b)
          o = @pts[k[0]]
          d = V.sub(@pts[k[1]], o)
          return nil if V.len(d) < @tol
          return [o, V.norm(d)]
        end
        nil
      end

      def least_squares(labs)
        a = [[0.0] * 3, [0.0] * 3, [0.0] * 3]
        b = [0.0, 0.0, 0.0]
        labs.each do |l|
          n, d = @planes[l]
          3.times do |i|
            3.times { |j| a[i][j] += n[i] * n[j] }
            b[i] += n[i] * d
          end
        end
        det = V.dot(a[0], V.cross(a[1], a[2]))
        return nil if det.abs < 1e-9
        cols = (0..2).map { |j| (0..2).map { |i| a[i][j] } }
        (0..2).map do |j|
          m = cols.dup
          m[j] = b
          V.dot(m[0], V.cross(m[1], m[2])) / det
        end
      end

      # The rebuilt face must be flat, must not cross itself, and holes must
      # lie inside its outline.
      def check_face(p, lps)
        n, d = @planes[p]
        lps.flatten(1).each do |q|
          raise Error, 'not recognised (a rebuilt face would not be flat).' if (V.dot(n, q) - d).abs > @plane_tol
        end
        ax = n.map(&:abs)
        keep = [0, 1, 2] - [ax.index(ax.max)]
        loops2 = lps.map { |lp| lp.map { |q| q.values_at(*keep) } }
        segs = []
        loops2.each_with_index do |lp, li|
          lp.each_index { |i| segs << [li, i, lp[i], lp[(i + 1) % lp.size], lp.size] }
        end
        segs.each_with_index do |(la, ia, a, b, na), x|
          ((x + 1)...segs.size).each do |y|
            lb, ib, c, e, _nb = segs[y]
            next if la == lb && ((ia - ib).abs == 1 || (ia - ib).abs == na - 1)
            if crossing?(a, b, c, e)
              raise Error, 'not recognised (a rebuilt face would cross itself).'
            end
          end
        end
        loops2[1..-1].each do |h|
          raise Error, 'not recognised (a rebuilt hole would leave its face).' unless inside?(h[0], loops2[0])
        end
      end

      def crossing?(a, b, c, d)
        o = lambda { |p, q, r| (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]) }
        eps = @tol * @size
        d1 = o.call(c, d, a)
        d2 = o.call(c, d, b)
        d3 = o.call(a, b, c)
        d4 = o.call(a, b, d)
        return true if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) &&
                       ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps))
        # touching (a point of one segment on the other)
        [[a, c, d, d1], [b, c, d, d2], [c, a, b, d3], [d, a, b, d4]].any? do |pt, s, t, side|
          side.abs <= eps && on_segment?(pt, s, t) && ![s, t].any? { |z| (z[0] - pt[0]).abs <= @tol && (z[1] - pt[1]).abs <= @tol }
        end
      end

      def on_segment?(p, a, b)
        p[0] >= [a[0], b[0]].min - @tol && p[0] <= [a[0], b[0]].max + @tol &&
          p[1] >= [a[1], b[1]].min - @tol && p[1] <= [a[1], b[1]].max + @tol
      end

      def inside?(pt, poly)
        x, y = pt
        r = false
        poly.size.times do |i|
          a = poly[i]
          b = poly[(i + 1) % poly.size]
          next unless (a[1] > y) != (b[1] > y)
          r = !r if x < a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
        end
        r
      end

      # Points closer than the merge distance become one point (exactly the
      # same coordinates in every face; an original corner wins).
      def point_id(q)
        cell = @merge * 4
        c = q.map { |x| (x / cell).floor }
        [-1, 0, 1].each do |i|
          [-1, 0, 1].each do |j|
            [-1, 0, 1].each do |l|
              (@grid[[c[0] + i, c[1] + j, c[2] + l]] || []).each do |id|
                return id if V.dist(@ids[id], q) <= @merge
              end
            end
          end
        end
        @ids << q
        (@grid[c] ||= []) << @ids.size - 1
        @ids.size - 1
      end

      def snap(result)
        @grid = {}
        @ids = []
        @pts.each_index { |i| point_id(@pts[i]) if !@rv[i] && @vert_faces.key?(i) }
        tol = [@plane_tol, @merge * 2].max
        result.each_key do |p|
          n, d = @planes[p]
          result[p] = result[p].map do |lp|
            out = dedupe(lp.map { |q| @ids[point_id(q)] })
            raise Error, 'not recognised (a rebuilt face would have no area).' if out.size < 3
            out.each do |q|
              raise Error, 'not recognised (a rebuilt face would not be flat).' if (V.dot(n, q) - d).abs > tol
            end
            out
          end
        end
      end

      # Every edge of the rebuilt faces must have a face on both sides (as
      # many as before for the edges that already existed), and faces on
      # both sides must face the same way (none turned over).
      def check_closed(result)
        pid = lambda { |q| point_id(q) }
        cnt = Hash.new(0)
        fwd = Hash.new(0)
        add = lambda do |ps|
          ps.each_index do |i|
            a = ps[i]
            b = ps[(i + 1) % ps.size]
            raise Error, 'not recognised (a rebuilt edge would be too short).' if a == b
            k = a < b ? [a, b] : [b, a]
            cnt[k] += 1
            fwd[k] += a < b ? 1 : -1
          end
        end
        result.each do |p, lps|
          n = normal(p)
          lps.each_with_index do |lp, li|
            ps = lp.map { |q| pid.call(q) }
            s = V.dot(V.newell(lp), n)
            ps.reverse! if (li == 0 && s < 0) || (li > 0 && s > 0)
            add.call(ps)
          end
        end
        vid = {}
        @pts.each_index { |i| vid[pid.call(@pts[i])] = i if !@rv[i] && @vert_faces.key?(i) }
        outset = {}
        @out.each { |f| outset[f] = true }
        # faces that stay as they are
        @faces.each_index do |f|
          next if @in[f] || outset[f]
          @faces[f][:loops].each do |lp|
            ps = lp.map { |v| pid.call(@pts[v]) }
            ps.reverse! if @flip[f]
            ps.each_index do |i|
              a = ps[i]
              b = ps[(i + 1) % ps.size]
              k = a < b ? [a, b] : [b, a]
              next unless cnt.key?(k)
              cnt[k] += 1
              fwd[k] += a < b ? 1 : -1
            end
          end
        end
        cnt.each do |(a, b), c|
          want = 2
          if vid[a] && vid[b]
            k = key(vid[a], vid[b])
            # an edge that existed: as many faces as before (its faces
            # outside the given ones are not counted)
            want = @edge_faces[k].size if @edge_faces.key?(k)
          end
          raise Error, 'not recognised (the rebuilt faces would not close up).' if c != want
          next unless c == 2
          raise Error, 'not recognised (a rebuilt face would be turned over).' if fwd[[a, b]] != 0
        end
      end
    end
  end
end
