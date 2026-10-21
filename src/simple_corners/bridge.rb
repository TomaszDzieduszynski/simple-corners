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

      fmt = lambda { |x| Sketchup.format_length(x) }
      # Fits the radius: smaller only at the corners where it does not fit.
      eng = Core::Engine.fit(pts, fdata, sel, opts.merge(:format => fmt))
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

    # Processes all edges of a group or component instance. Component
    # definitions are shared: every instance of it changes.
    def self.process_instance(inst, opts)
      if inst.is_a?(Sketchup::Group) && inst.definition.instances.size > 1
        inst.make_unique
      end
      ents = inst.definition.entities
      process(ents, ents.grep(Sketchup::Edge), opts)
    end

    # Attribute dictionary on the faces this extension creates (op id, mode,
    # radius), so a rounded surface can be found again later.
    DICT = 'SimpleCorners'.freeze

    def self.apply(ents, eng, faces, verts, opts = {})
      pts = eng.points
      gp = lambda { |id| Geom::Point3d.new(pts[id][0], pts[id][1], pts[id][2]) }

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

      to_erase = eng.face_loops.keys.map { |fi| faces[fi] } + removed
      ents.erase_entities(to_erase.select(&:valid?))

      before = {}
      ents.grep(Sketchup::Face).each { |f| before[f] = true }
      created = []
      failed = 0

      eng.face_loops.each do |fi, loops|
        f = add_face(ents, loops[0].map(&gp))
        unless f
          failed += 1
          next
        end
        f.reverse! if f.normal.dot(Geom::Vector3d.new(*fattr[fi][:normal])) < 0
        apply_face_attrs(f, fattr[fi])
        created << f
        loops[1..-1].each do |lp|
          hole = add_face(ents, lp.map(&gp))
          hole.erase! if hole && hole.valid? && hole != f && !before[hole]
        end
      end

      eng.new_polys.each do |poly|
        q = poly[:ids].map(&gp)
        f = add_face(ents, q)
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
        end
        created << f
      end

      if failed > 0
        raise Error, "#{failed} face(s) could not be created. The new geometry is probably " \
                     'too small for SketchUp (tolerance 0.001"). Try a larger offset or fewer ' \
                     'segments, or scale the model up (x10 or x100), apply, and scale it back.'
      end

      finish_edges(created, eng, trim_info, opts[:smooth] != false)
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? }
    end

    def self.add_face(ents, pts)
      clean = []
      pts.each { |p| clean << p if clean.empty? || clean.last.distance(p) > MIN_DIST }
      clean.pop while clean.size > 1 && clean.last.distance(clean.first) <= MIN_DIST
      return nil if clean.size < 3
      ents.add_face(clean)
    rescue ArgumentError
      nil
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
