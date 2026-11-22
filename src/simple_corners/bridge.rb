# Simple Corners - link between the SketchUp model and the geometry engine.
#
# Reads the faces around the edges to process, runs Core::Engine, then
# replaces the affected faces by the new geometry inside one entities
# collection. Must be called inside an operation (model.start_operation).
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

module SimpleCorners
  module Bridge
    class Error < StandardError; end

    # Rounding used to match computed points with created vertices (inches).
    KEY_STEP = 1e-5
    # Points closer than this are merged before creating a face (SketchUp
    # cannot create edges shorter than its 0.001" tolerance).
    MIN_DIST = 0.0011

    # Runs the engine on edges without changing the model.
    # Returns [engine, faces, vertices] (raises Core::Error).
    # opts[:space]: a Space when the edges are inside a scaled group or
    # component; the engine then works in model units (its points are model
    # coordinates; Space#to_local brings them back).
    def self.compute(edges, opts)
      edges = edges.select { |e| e.valid? && e.is_a?(Sketchup::Edge) }.uniq
      raise Core::Error, 'No edge selected.' if edges.empty?
      space = opts[:space]

      vmap = {}
      verts = []
      pts = []
      vid = lambda do |vx|
        id = vmap[vx]
        unless id
          id = verts.size
          vmap[vx] = id
          verts << vx
          pts << (space ? space.to_model(vx.position.to_a) : vx.position.to_a)
        end
        id
      end

      affected = edges.flat_map(&:vertices).uniq
      faces = affected.flat_map(&:faces).uniq
      fdata = faces.map do |f|
        outer = f.outer_loop
        loops = [outer] + f.loops.reject(&:outer?)
        { :loops => loops.map { |lp| lp.vertices.map { |vx| vid.call(vx) } },
          :normal => space ? space.normal(f.normal.to_a) : f.normal.to_a }
      end
      sel = edges.map { |e| [vid.call(e.start), vid.call(e.end)] }
      # Given radius per edge ({Sketchup::Edge => offset}, e.g. rounding
      # edges again as they were): used as is, only reduced if needed.
      if opts[:edge_offsets]
        start = {}
        edges.each do |e|
          d = opts[:edge_offsets][e]
          next unless d
          a = vid.call(e.start)
          b = vid.call(e.end)
          start[a < b ? [a, b] : [b, a]] = d
        end
        opts = opts.merge(:start_offsets => start, :refine => false)
      end

      fmt = lambda { |x| Sketchup.format_length(x) }
      # Fits the radius: smaller only at the corners where it does not fit.
      # Points closer than MIN_DIST inside the group must merge: in model
      # units that is up to MIN_DIST times the largest scale.
      merge = space ? MIN_DIST * space.max_scale : MIN_DIST
      eng = Core::Engine.fit(pts, fdata, sel, opts.merge(:format => fmt, :merge_dist => merge))
      [eng, faces, verts]
    end

    # Processes edges (and edges of faces) of one entities collection.
    # Returns an Array of warning messages. Raises Core::Error or
    # Bridge::Error on failure (the caller aborts the operation).
    def self.process(entities, edges, opts)
      edges = edges.select { |e| e.valid? && e.is_a?(Sketchup::Edge) }.uniq
      return [] if edges.empty?
      eng, faces, verts = compute(edges, opts)
      apply(entities, eng, faces, verts, opts)
      warnings = eng.warnings.dup
      unless eng.reduced.empty?
        dmin = eng.reduced.values.min
        warnings << "Radius reduced on #{eng.reduced.size} edge(s) to fit (smallest #{Sketchup.format_length(dmin)})."
      end
      warnings
    end

    # Deepest nesting of groups/components that is processed.
    MAX_DEPTH = 32

    # Processes all edges of a group or component instance, and of the
    # groups and components nested in it. A group that shares its
    # definition with copies is made unique first, so only this copy
    # changes. Component definitions are shared on purpose: each is
    # processed once (done: definitions already processed) and every
    # instance of it changes.
    # tr: the instance's placement in the model (its transformation times
    # those of the instances holding it); the radius is measured in the
    # model, also in a scaled or stretched group.
    # Sets done[:processed] when a level had edges to round; the caller
    # reports a selection with nothing to round once, after all of it.
    # Locked instances (nested ones too) are left as they are: done[:locked].
    def self.process_instance(inst, opts, done = {}, depth = 0, tr = inst.transformation)
      return [] if depth > MAX_DEPTH
      if locked?(inst)
        done[:locked] = true
        return []
      end
      if inst.is_a?(Sketchup::Group)
        inst.make_unique if inst.definition.instances.size > 1
      else
        return [] if done[inst.definition]
      end
      d = inst.definition
      done[d] = true
      ents = d.entities
      edges = ents.grep(Sketchup::Edge)
      # A level with nothing to round (loose flat faces, only nested
      # objects) is passed over, so its nested objects still get done.
      warnings = []
      if edges.any? { |e| usable_edge?(e) }
        warnings = process(ents, edges, opts.merge(:space => Space.for(tr), :metric => metric(tr)))
        done[:processed] = true
      end
      nested = ents.to_a.select { |e| e.valid? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) }
      nested.each do |e|
        warnings.concat(process_instance(e, opts, done, depth + 1, tr * e.transformation))
      end
      warnings
    end

    # How a placement scales lengths, independent of moving, rotating and
    # mirroring: the 6 numbers of M^T M (M: its scaling part). Stored with
    # the radius on new faces, so a later change of the group's scale can
    # be recognised (Revert then measures instead of trusting the number).
    def self.metric(tr)
      return [1.0, 0.0, 0.0, 1.0, 0.0, 1.0] unless tr
      a = tr.to_a.map(&:to_f)
      w = a[15].abs > 1e-12 ? a[15] : 1.0
      c = [[a[0], a[1], a[2]], [a[4], a[5], a[6]], [a[8], a[9], a[10]]].map { |v| v.map { |x| x / w } }
      g = lambda { |i, j| c[i][0] * c[j][0] + c[i][1] * c[j][1] + c[i][2] * c[j][2] }
      [g.call(0, 0), g.call(0, 1), g.call(0, 2), g.call(1, 1), g.call(1, 2), g.call(2, 2)]
    end

    def self.same_metric?(a, b)
      return false unless a.is_a?(Array) && b.is_a?(Array) && a.size == 6 && b.size == 6
      big = (a + b).map { |x| x.to_f.abs }.max
      a.zip(b).all? { |x, y| (x.to_f - y.to_f).abs <= 1e-6 * big }
    end

    # b is a uniformly scaled a (lengths changed by the same factor in every
    # direction, or not at all).
    def self.uniform_change?(a, b)
      return false unless a.is_a?(Array) && b.is_a?(Array) && a.size == 6 && b.size == 6
      ta = a[0].to_f + a[3].to_f + a[5].to_f
      tb = b[0].to_f + b[3].to_f + b[5].to_f
      return false unless ta > 0 && tb > 0
      same_metric?(a.map { |x| x.to_f * tb / ta }, b)
    end

    # Scale of the coordinates the API reports in the open context: those
    # of the open group or component (SketchUp reports model coordinates
    # there), or of the model.
    def self.context_metric(model)
      path = model.active_path
      return metric(nil) unless path && !path.empty? && model.respond_to?(:edit_transform)
      metric(model.edit_transform)
    end

    NOTHING_TO_ROUND = 'No edge can be processed. Edges must border exactly two non-coplanar faces.'.freeze
    LOCKED = 'the group or component is locked. Unlock it first (right-click > Unlock).'.freeze
    LOCKED_SKIPPED = 'Locked groups and components were left unchanged.'.freeze

    # Locked groups and components: SketchUp's own tools leave them alone
    # (its Ruby API would not stop an edit).
    def self.locked?(e)
      e.respond_to?(:locked?) && e.locked? ? true : false
    end

    # The coordinates of a scaled or stretched group or component, so the
    # engine can work in model units: a radius of 1" is then 1" in the
    # model in every direction (a true circle as seen in the model, even in
    # a group stretched along one axis). Scaling, stretching, shearing,
    # rotation and mirroring keep faces flat and edges straight, so the
    # result brought back into the group is valid geometry.
    # Only the scaling part of the placement is applied, not its position:
    # the numbers stay as small as the group's own (a group far from the
    # origin would otherwise lose precision in the engine).
    class Space
      # nil when the group is not scaled (only moved, rotated or mirrored):
      # its own units are then model units.
      def self.for(tr)
        return nil unless tr
        sp = new(tr)
        sp.isometry? ? nil : sp
      end

      def initialize(tr)
        a = tr.to_a.map(&:to_f)
        # SketchUp may keep a uniform scale in the last element.
        w = a[15].abs > 1e-12 ? a[15] : 1.0
        @m = [[a[0], a[4], a[8]], [a[1], a[5], a[9]], [a[2], a[6], a[10]]].map { |r| r.map { |x| x / w } }
        m = @m
        cof = [[m[1][1] * m[2][2] - m[1][2] * m[2][1], m[1][2] * m[2][0] - m[1][0] * m[2][2], m[1][0] * m[2][1] - m[1][1] * m[2][0]],
               [m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1]],
               [m[0][1] * m[1][2] - m[0][2] * m[1][1], m[0][2] * m[1][0] - m[0][0] * m[1][2], m[0][0] * m[1][1] - m[0][1] * m[1][0]]]
        det = m[0][0] * cof[0][0] + m[0][1] * cof[0][1] + m[0][2] * cof[0][2]
        # flat (zero size in some direction), relative to the axes' lengths,
        # so a valid but very small or very large scale is accepted
        cols = (0..2).map { |j| Math.sqrt(m[0][j]**2 + m[1][j]**2 + m[2][j]**2) }
        if det.abs <= 1e-12 * cols.inject(:*) || det.zero?
          raise Error, 'the group or component is scaled to zero size.'
        end
        # inverse = transposed cofactors / det; normals go through the
        # inverse transposed (cofactors / det)
        @inv = (0..2).map { |i| (0..2).map { |j| cof[j][i] / det } }
        @nrm = cof.map { |r| r.map { |x| x / det } }
      end

      # Group coordinates -> engine coordinates (model units, group origin).
      def to_model(p)
        m = @m
        (0..2).map { |i| m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] }
      end

      def to_local(q)
        (0..2).map { |i| @inv[i][0] * q[0] + @inv[i][1] * q[1] + @inv[i][2] * q[2] }
      end

      # Normal of a face in model space (unit length).
      def normal(n)
        v = (0..2).map { |i| @nrm[i][0] * n[0] + @nrm[i][1] * n[1] + @nrm[i][2] * n[2] }
        len = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
        len > 0 ? v.map { |x| x / len } : n
      end

      # Largest length an inch of the group's axes has in the model.
      def max_scale
        (0..2).map { |j| Math.sqrt(@m[0][j]**2 + @m[1][j]**2 + @m[2][j]**2) }.max
      end

      # Lengths unchanged (moved, rotated or mirrored only).
      def isometry?
        (0..2).all? do |i|
          (0..2).all? do |j|
            d = @m[0][i] * @m[0][j] + @m[1][i] * @m[1][j] + @m[2][i] * @m[2][j]
            (d - (i == j ? 1.0 : 0.0)).abs < 1e-9
          end
        end
      end
    end

    # An edge the engine can round: between two faces that are not
    # coplanar (the engine's own test).
    def self.usable_edge?(e)
      fs = e.faces
      return false unless fs.size == 2 && fs[0] != fs[1]
      Core::V.len(Core::V.cross(Core::V.norm(fs[0].normal.to_a), Core::V.norm(fs[1].normal.to_a))) >= 1e-6
    end

    # Attribute dictionary on the faces this extension creates (op id, mode,
    # radius), so a rounded surface can be found again later.
    DICT = 'SimpleCorners'.freeze

    def self.apply(ents, eng, faces, verts, opts = {})
      # The engine worked in model units in a scaled group: back to the
      # group's own coordinates.
      space = opts[:space]
      pts = space ? eng.points.map { |p| space.to_local(p) } : eng.points
      gp = welder(pts, verts)

      # Remember what must survive the rebuild.
      fattr = {}
      eng.face_loops.each_key { |fi| fattr[fi] = face_attrs(faces[fi]) }
      ident = {}
      eng.face_loops.each_key { |fi| ident[fi] = identity_of(faces[fi]) }
      eng.new_polys.each { |p| fattr[p[:src]] ||= face_attrs(faces[p[:src]]) }
      old_edges = eng.face_loops.keys.flat_map { |fi| faces[fi].edges }.uniq
      removed = eng.removed_edges.map { |a, b| verts[a].common_edge(verts[b]) }.compact.uniq
      trimmed = {}
      eng.trimmed_edges.each { |k| trimmed[k] = true }
      trim_info = []
      eng.removed_edges.each do |k|
        next unless trimmed[k]
        e = verts[k[0]].common_edge(verts[k[1]])
        trim_info << [e.start.position, e.end.position, edge_attrs(e)] if e
      end

      # Everything new is built first in a temporary group, away from the
      # model: if SketchUp refuses a face, the group is deleted and the
      # model has not changed at all. (SketchUp 2017 does not always roll
      # back an aborted operation in which faces were erased and a new face
      # was refused; the model was left half rebuilt, beyond undo.) Only
      # then are the old faces erased and the group exploded in place.
      tmp = ents.add_group
      te = tmp.entities
      # An empty group can be discarded by SketchUp as soon as another
      # group is added inside it (faces with holes are built that way):
      # a construction point keeps it until it is exploded.
      guard = te.add_cpoint(Geom::Point3d.new(0, 0, 0))
      failed = 0

      eng.face_loops.each do |fi, loops|
        f = add_face_loops(te, loops.map { |lp| lp.map(&gp) }) do |x|
          x.reverse! if x.normal.dot(Geom::Vector3d.new(*fattr[fi][:normal])) < 0
          apply_face_attrs(x, fattr[fi])
          # the trimmed face stays the same face (new faces do not get this)
          give_identity(x, ident[fi])
        end
        failed += 1 unless f
      end

      eng.new_polys.each do |poly|
        q = poly[:ids].map(&gp)
        # A sliver whose corners SketchUp merges anyway: nothing to make.
        next if sliver?(q)
        f = add_face(te, q)
        unless f
          failed += 1
          next
        end
        f.reverse! if f.normal.dot(newell(q)) < 0
        apply_face_attrs(f, fattr[poly[:src]])
        if opts[:op_id]
          f.set_attribute(DICT, 'op', opts[:op_id])
          f.set_attribute(DICT, 'mode', opts[:mode].to_s)
          f.set_attribute(DICT, 'radius', opts[:offset].to_f)
          # the scale that radius was measured in (see metric)
          f.set_attribute(DICT, 'metric', opts[:metric]) if opts[:metric]
          f.set_attribute(DICT, 'segments', opts[:segments].to_i) if opts[:segments]
          f.set_attribute(DICT, 'smooth', opts[:smooth] != false)
        end
      end

      if failed > 0
        tmp.erase!
        raise Error, "#{failed} face(s) could not be created. The new geometry is probably " \
                     'too small for SketchUp (tolerance 0.001"). Try a larger offset or fewer ' \
                     'segments, or scale the model up (x10 or x100), apply, and scale it back.'
      end

      # Edges that are open (one face) already stay allowed to be.
      open_before = {}
      faces.each { |f| f.edges.each { |e| open_before[edge_key(e)] = true if e.faces.size == 1 } }

      to_erase = eng.face_loops.keys.map { |fi| faces[fi] } + removed
      ents.erase_entities(to_erase.select(&:valid?))
      drop_stray_edges(old_edges, te)
      guard.erase! if guard.valid?
      created = explode_new(tmp)

      finish_edges(created, eng, trim_info, opts[:smooth] != false, pts)
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? }
      check_closed(created, open_before)
    end

    # Before the new faces are exploded in place: old edges left without a
    # face that are not edges of the new faces would be welded into them
    # and split them, so they go first. Those the new faces use again stay
    # (with their properties).
    def self.drop_stray_edges(old_edges, new_ents)
      keep = {}
      new_ents.grep(Sketchup::Face).each { |f| f.edges.each { |e| keep[edge_key(e)] = true } }
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? && !keep[edge_key(e)] }
    end

    def self.edge_key(e)
      [pkey(e.start.position), pkey(e.end.position)].sort
    end

    # The new faces must close up with the model: an edge of theirs with a
    # face on one side only (that was not so before) is a gap, e.g. where
    # points end up a little more than SketchUp's tolerance apart.
    # Raises Error; the caller aborts the operation, so nothing changes.
    # Strict: SketchUp does not weld points that are merely very close when
    # the new faces are exploded in place (seen 0.0004" apart in a scaled
    # component), so any open edge is a gap.
    def self.check_closed(created, open_before)
      gap = created.select(&:valid?).flat_map(&:edges).uniq.find do |e|
        e.faces.size == 1 && !open_before[edge_key(e)]
      end
      return unless gap
      raise Error, "the result would not close up near #{Sketchup.format_length(gap.length)} long edge at " \
                   "#{gap.start.position.to_a.map { |x| Sketchup.format_length(x) }.join(', ')} (points end " \
                   'up a little more than SketchUp\'s 0.001" tolerance apart). Try another radius, or scale ' \
                   'the model up (x10 or x100), apply, and scale it back.'
    end

    # Fewer than three points left once points closer than SketchUp's
    # tolerance are merged.
    def self.sliver?(pts)
      keep = []
      pts.each { |p| keep << p unless keep.any? { |k| k.distance(p) <= MIN_DIST } }
      keep.size < 3
    end

    # Points closer than this are one point (SketchUp's tolerance).
    WELD_DIST = 0.001

    # Point of an engine point id, welded: a point within WELD_DIST of an
    # existing vertex or of a point made before is that point. SketchUp
    # snaps a new face to the vertices around it, but the new faces are
    # built in a group of their own, and exploding it does not weld points
    # that are merely close; without this, such points would leave
    # hairline gaps.
    def self.welder(pts, verts)
      cell = WELD_DIST * 2
      grid = {}
      key = lambda { |a| [(a[0] / cell).floor, (a[1] / cell).floor, (a[2] / cell).floor] }
      put = lambda { |p| (grid[key.call(p.to_a)] ||= []) << p }
      find = lambda do |p|
        a = p.to_a
        k = key.call(a)
        [-1, 0, 1].each do |i|
          [-1, 0, 1].each do |j|
            [-1, 0, 1].each do |l|
              (grid[[k[0] + i, k[1] + j, k[2] + l]] || []).each { |q| return q if q.distance(p) <= WELD_DIST }
            end
          end
        end
        nil
      end
      verts.each { |vx| put.call(vx.position) }
      done = {}
      lambda do |id|
        done[id] ||= begin
          p = Geom::Point3d.new(pts[id][0], pts[id][1], pts[id][2])
          q = find.call(p)
          if q
            q
          else
            put.call(p)
            p
          end
        end
      end
    end

    def self.add_face(ents, pts)
      clean = []
      pts.each { |p| clean << p if clean.empty? || clean.last.distance(p) > MIN_DIST }
      clean.pop while clean.size > 1 && clean.last.distance(clean.first) <= MIN_DIST
      return nil if clean.size < 3
      # An outline through one point more than once: as simple loops.
      return add_face_loops(ents, [clean]) if clean.map { |p| pkey(p) }.uniq.size < clean.size
      ents.add_face(clean)
    rescue ArgumentError
      nil
    end

    # Splits a loop that passes through a point more than once into simple
    # loops. Such loops come from faces whose outline runs out and back
    # over edges, e.g. edges that join the outline of a face to one of its
    # holes (the top of a ring of walls crossed by a partition). SketchUp
    # makes such faces itself, but cannot take that outline back in
    # add_face: it fails, and the failure damages the entities it was
    # called on (later calls find them deleted, and an aborted operation
    # is not rolled back). Pieces without area (the out-and-back parts)
    # are dropped.
    def self.simple_loops(pts)
      keys = pts.map { |p| pkey(p) }
      n = pts.size
      n.times do |i|
        ((i + 1)...n).each do |j|
          next unless keys[i] == keys[j]
          return simple_loops(pts[i...j]) + simple_loops(pts[j..-1] + pts[0...i])
        end
      end
      return [] if n < 3 || newell(pts).length.to_f < MIN_DIST * MIN_DIST
      [pts]
    end

    # Whether 2D loop a lies inside 2D loop b (loops that do not cross,
    # but may touch): tested at the first point of a's outline, corner or
    # edge middle, that is not on b's outline.
    def self.loop_inside?(a, b)
      n = a.size
      cand = a + (0...n).map { |i| [(a[i][0] + a[(i + 1) % n][0]) / 2.0, (a[i][1] + a[(i + 1) % n][1]) / 2.0] }
      q = cand.find { |c| (0...b.size).all? { |i| seg_dist2d(c, b[i], b[(i + 1) % b.size]) > MIN_DIST } }
      q ? inside2d?(q, b) : false
    end

    # Distance from 2D point q to segment ab.
    def self.seg_dist2d(q, a, b)
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      dd = dx * dx + dy * dy
      t = dd > 0 ? [[((q[0] - a[0]) * dx + (q[1] - a[1]) * dy) / dd, 0.0].max, 1.0].min : 0.0
      Math.hypot(q[0] - a[0] - t * dx, q[1] - a[1] - t * dy)
    end

    # A point inside a 2D polygon (the middle of a corner triangle that
    # lies in it), or nil.
    def self.point_inside(poly)
      n = poly.size
      n.times do |i|
        a = poly[i - 1]
        b = poly[i]
        c = poly[(i + 1) % n]
        q = [(a[0] + b[0] + c[0]) / 3.0, (a[1] + b[1] + c[1]) / 3.0]
        return q if inside2d?(q, poly)
      end
      nil
    end

    # Creates a face with holes (loops of points, outer first) and returns
    # it (nil if it could not be created). The block, if given, gets the
    # face first, to turn it the right way and set its properties.
    #
    # SketchUp cuts a hole when a face is added inside another one and
    # erased again, but not reliably among other geometry: a hole that
    # already has a face in it (touching its outline) is not cut, and the
    # face comes out covering the hole. So a face with holes is built on
    # its own in a temporary group, which is then exploded in place:
    # SketchUp merges it with what is there as if it had been drawn.
    #
    # Loops that pass through a point more than once are split into simple
    # ones first (see simple_loops); what is an outline and what a hole is
    # then decided by where the loops lie. Several outlines make several
    # faces: the largest is returned, and nil if any could not be made.
    def self.add_face_loops(ents, loops, &blk)
      simple = loops.flat_map { |lp| simple_loops(lp) }
      return nil if simple.empty?
      return face_with_holes(ents, simple, &blk) if simple == loops
      ax = newell(simple.max_by { |lp| newell(lp).length.to_f }).to_a.map(&:abs)
      keep = [0, 1, 2] - [ax.index(ax.max)]
      flat = simple.map { |lp| lp.map { |p| p.to_a.values_at(*keep) } }
      # within[k][o]: loop k lies inside loop o. The loops do not cross, so
      # one point of k's outline that is not on o's tells. (A point inside
      # k would not do: in a thin ring it can lie in the hole.)
      within = flat.each_index.map do |k|
        flat.each_index.map { |o| o != k && loop_inside?(flat[k], flat[o]) }
      end
      depth = flat.each_index.map { |k| within[k].count(true) }
      area = simple.map { |lp| newell(lp).length.to_f }
      faces = []
      flat.each_index.select { |k| depth[k].even? }.each do |k|
        holes = flat.each_index.select do |h|
          next false unless depth[h] == depth[k] + 1 && within[h][k]
          # the smallest outline around it is its own
          flat.each_index.none? { |o| o != k && depth[o] == depth[k] && area[o] < area[k] && within[h][o] }
        end
        f = face_with_holes(ents, [simple[k]] + holes.map { |h| simple[h] }, &blk)
        return nil unless f
        faces << f
      end
      faces.select(&:valid?).max_by(&:area)
    end

    # One face with holes (outer first); see add_face_loops.
    def self.face_with_holes(ents, loops)
      if loops.size == 1
        f = add_face(ents, loops[0])
        yield f if f && block_given?
        return f
      end
      g = ents.add_group
      ge = g.entities
      f = add_face(ge, loops[0])
      unless f
        g.erase!
        return nil
      end
      # A hole SketchUp refuses would leave the face covering it, with
      # open edges around it: then the face is not made at all.
      unless loops[1..-1].all? { |lp| add_face(ge, lp) }
        g.erase!
        return nil
      end
      # Either of two faces may be the piece inside the hole: tell them
      # apart by where they lie.
      ax = newell(loops[0]).to_a.map(&:abs)
      keep = [0, 1, 2] - [ax.index(ax.max)]
      holes = loops[1..-1].map { |lp| lp.map { |p| p.to_a.values_at(*keep) } }
      ge.grep(Sketchup::Face).each do |x|
        q = inner_point(x, keep)
        x.erase! if q && holes.any? { |h| inside2d?(q, h) }
      end
      left = ge.grep(Sketchup::Face)
      # Every hole must be open: no face left covers a point inside it.
      if left.empty? || holes.any? { |h| (q = point_inside(h)).nil? || left.any? { |x| covers?(x, q, keep) } }
        g.erase!
        return nil
      end
      left.each { |x| yield x } if block_given?
      (g.explode || []).grep(Sketchup::Face).max_by(&:area)
    end

    # Whether face f covers the 2D point q (inside its outline, not in a
    # hole of it).
    def self.covers?(f, q, keep)
      f.loops.all? do |lp|
        inside2d?(q, lp.vertices.map { |v| v.position.to_a.values_at(*keep) }) == lp.outer?
      end
    end

    # A point inside face f, in 2D (the coordinates keep): the middle of
    # a corner triangle of its outline that lies in the face.
    def self.inner_point(f, keep)
      outer = f.outer_loop.vertices.map { |v| v.position.to_a.values_at(*keep) }
      inner = f.loops.reject(&:outer?).map { |lp| lp.vertices.map { |v| v.position.to_a.values_at(*keep) } }
      n = outer.size
      n.times do |i|
        a = outer[i - 1]
        b = outer[i]
        c = outer[(i + 1) % n]
        q = [(a[0] + b[0] + c[0]) / 3.0, (a[1] + b[1] + c[1]) / 3.0]
        return q if inside2d?(q, outer) && inner.none? { |h| inside2d?(q, h) }
      end
      nil
    end

    # Point in polygon (2D, even-odd rule).
    def self.inside2d?(q, poly)
      x, y = q
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

    def self.newell(pts)
      n = [0.0, 0.0, 0.0]
      k = pts.size
      k.times do |i|
        a = pts[i]
        b = pts[(i + 1) % k]
        n[0] += (a.y - b.y) * (a.z + b.z)
        n[1] += (a.z - b.z) * (a.x + b.x)
        n[2] += (a.x - b.x) * (a.y + b.y)
      end
      Geom::Vector3d.new(n[0], n[1], n[2])
    end

    def self.face_attrs(f)
      { :material => f.material, :back_material => f.back_material,
        :layer => f.layer, :normal => f.normal.to_a }
    end

    def self.apply_face_attrs(f, h)
      return unless h
      f.material = h[:material] if h[:material]
      f.back_material = h[:back_material] if h[:back_material]
      f.layer = h[:layer] if h[:layer]
    end

    # What keeps a trimmed face the same face for the user and for other
    # extensions: hidden or not, and its attribute dictionaries (with any
    # dictionaries nested in them). Only the face that replaces it gets
    # these, never the new faces of a rounding.
    def self.identity_of(f)
      { :hidden => f.hidden?, :dicts => dict_tree(f) }
    end

    def self.give_identity(f, h)
      return unless h
      f.hidden = true if h[:hidden]
      put_dicts(f, h[:dicts])
    end

    def self.dict_tree(ent)
      ds = ent.respond_to?(:attribute_dictionaries) ? ent.attribute_dictionaries : nil
      return [] unless ds
      ds.map do |d|
        pairs = []
        d.each_pair { |k, v| pairs << [k, v] }
        [d.name, pairs, dict_tree(d)]
      end
    end

    def self.put_dicts(ent, tree)
      tree.each do |name, pairs, kids|
        d = ent.attribute_dictionary(name, true)
        pairs.each { |k, v| d[k] = v }
        put_dicts(d, kids)
      end
    end

    # Explodes the temporary group holding the new faces; returns the new
    # faces. If SketchUp cannot explode it, the group is still there: the
    # error makes the caller abort the operation, so the model goes back
    # to how it was instead of keeping half a rebuild. (Checked by the
    # group still existing, not only by the result, which SketchUp gives
    # as false.)
    def self.explode_new(tmp)
      res = tmp.explode
      if tmp.valid? || !res.respond_to?(:grep)
        raise Error, 'SketchUp could not place the new faces in the model (exploding their temporary group failed).'
      end
      res.grep(Sketchup::Face)
    end

    def self.edge_attrs(e)
      { :soft => e.soft?, :smooth => e.smooth?, :hidden => e.hidden?,
        :material => e.material, :layer => e.layer }
    end

    def self.pkey(p)
      a = p.to_a
      [(a[0] / KEY_STEP).round, (a[1] / KEY_STEP).round, (a[2] / KEY_STEP).round]
    end

    # Softens the edges flagged by the engine and gives the remaining parts
    # of trimmed edges their original properties.
    # smooth false: the segment lines of rounded surfaces stay visible (only
    # the diagonals of split quads are softened).
    def self.finish_edges(created, eng, trim_info, smooth = true, pts = eng.points)
      softset = smooth ? eng.soft : eng.diagonals
      ids = {}
      softset.each_key do |a, b|
        ids[pkey(pts[a])] = a
        ids[pkey(pts[b])] = b
      end
      seen = {}
      created.each do |f|
        next unless f.valid?
        f.edges.each do |e|
          next if seen[e]
          seen[e] = true
          ia = ids[pkey(e.start.position)]
          ib = ids[pkey(e.end.position)]
          if ia && ib && softset[ia < ib ? [ia, ib] : [ib, ia]]
            e.soft = true
            e.smooth = true
            next
          end
          trim_info.each do |p0, p1, at|
            next unless on_segment?(e.start.position, p0, p1) && on_segment?(e.end.position, p0, p1)
            e.soft = at[:soft]
            e.smooth = at[:smooth]
            e.hidden = at[:hidden]
            e.material = at[:material] if at[:material]
            e.layer = at[:layer] if at[:layer]
            break
          end
        end
      end
    end

    def self.on_segment?(p, a, b)
      ab = b - a
      len = ab.length.to_f
      return false if len <= 0.0
      t = (p - a).dot(ab) / (len * len)
      return false if t < -1e-6 || t > 1.0 + 1e-6
      proj = Geom::Point3d.new(a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t)
      proj.distance(p).to_f < 1e-4
    end
  end
end
