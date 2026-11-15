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
    def self.compute(edges, opts)
      edges = edges.select { |e| e.valid? && e.is_a?(Sketchup::Edge) }.uniq
      raise Core::Error, 'No edge selected.' if edges.empty?

      vmap = {}
      verts = []
      pts = []
      vid = lambda do |vx|
        id = vmap[vx]
        unless id
          id = verts.size
          vmap[vx] = id
          verts << vx
          pts << vx.position.to_a
        end
        id
      end

      affected = edges.flat_map(&:vertices).uniq
      faces = affected.flat_map(&:faces).uniq
      fdata = faces.map do |f|
        outer = f.outer_loop
        loops = [outer] + f.loops.reject(&:outer?)
        { :loops => loops.map { |lp| lp.vertices.map { |vx| vid.call(vx) } },
          :normal => f.normal.to_a }
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
      eng = Core::Engine.fit(pts, fdata, sel, opts.merge(:format => fmt, :merge_dist => MIN_DIST))
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
    def self.process_instance(inst, opts, done = {}, depth = 0)
      return [] if depth > MAX_DEPTH
      if inst.is_a?(Sketchup::Group)
        inst.make_unique if inst.definition.instances.size > 1
      else
        return [] if done[inst.definition]
      end
      d = inst.definition
      done[d] = true
      ents = d.entities
      warnings = process(ents, ents.grep(Sketchup::Edge), opts)
      nested = ents.to_a.select { |e| e.valid? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) }
      nested.each do |e|
        sub = opts.merge(:offset => opts[:offset] / SimpleCorners.scale_of(e.transformation))
        warnings.concat(process_instance(e, sub, done, depth + 1))
      end
      warnings
    end

    # Attribute dictionary on the faces this extension creates (op id, mode,
    # radius), so a rounded surface can be found again later.
    DICT = 'SimpleCorners'.freeze

    def self.apply(ents, eng, faces, verts, opts = {})
      pts = eng.points
      gp = welder(pts, verts)

      # Remember what must survive the rebuild.
      fattr = {}
      eng.face_loops.each_key { |fi| fattr[fi] = face_attrs(faces[fi]) }
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
      created = (tmp.explode || []).grep(Sketchup::Face)

      finish_edges(created, eng, trim_info, opts[:smooth] != false)
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
      inner = flat.map { |pl| point_inside(pl) }
      return nil if inner.any?(&:nil?)
      depth = flat.each_index.map { |k| flat.each_index.count { |o| o != k && inside2d?(inner[k], flat[o]) } }
      area = simple.map { |lp| newell(lp).length.to_f }
      faces = []
      flat.each_index.select { |k| depth[k].even? }.each do |k|
        holes = flat.each_index.select do |h|
          next false unless depth[h] == depth[k] + 1 && inside2d?(inner[h], flat[k])
          # the smallest outline around it is its own
          flat.each_index.none? { |o| o != k && depth[o] == depth[k] && area[o] < area[k] && inside2d?(inner[h], flat[o]) }
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
      loops[1..-1].each { |lp| add_face(ge, lp) }
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
      if left.empty?
        g.erase!
        return nil
      end
      left.each { |x| yield x } if block_given?
      (g.explode || []).grep(Sketchup::Face).max_by(&:area)
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
    def self.finish_edges(created, eng, trim_info, smooth = true)
      softset = smooth ? eng.soft : eng.diagonals
      ids = {}
      softset.each_key do |a, b|
        ids[pkey(eng.points[a])] = a
        ids[pkey(eng.points[b])] = b
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
