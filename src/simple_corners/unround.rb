# Simple Corners - revert a simple rounded or bevelled edge to a sharp edge,
# from the geometry alone (no stored data needed).
#
# Recognised case: the selected faces form one surface (a fillet or chamfer
# along one edge) whose outline is a single loop with two flat side faces
# along it. The side faces are extended until they meet (the original
# edge). Each end is either one flat end face, which is extended to the
# edge's end point, or other rounded/bevelled geometry (corner patches,
# neighbouring strips), which stays: a small flat cap then closes the gap.
# Anything unclear is reported as not recognised and nothing changes.
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

module SimpleCorners
  module Unround
    class Error < StandardError; end

    V = Core::V
    # Side faces must meet at least at this angle (shallow corners such as
    # those of a many-sided prism are fine). Part of a rounded surface is
    # reverted too: its neighbouring facets are extended until they meet.
    MIN_SIDE_ANGLE = 3.0

    # Reverts the selected surface. Returns true when the model changed.
    def self.run(model = Sketchup.active_model)
      ctx = SimpleCorners.context_parent(model)
      faces = model.selection.to_a.grep(Sketchup::Face).select { |f| f.parent == ctx }
      begin
        raise Error, 'select the rounded or bevelled surface first (click it).' if faces.empty?
        plan = analyse(faces)
        model.start_operation('Revert Corner', true)
        begin
          apply(model.active_entities, faces, plan)
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
      rescue Error => err
        UI.messagebox("Revert corner: #{err.message}")
        return false
      rescue StandardError => err
        SimpleCorners.log_error('Revert corner', err, true)
        UI.messagebox("Revert corner failed: #{err.message}\n(details in Window > Ruby Console)")
        return false
      end
      model.selection.clear
      Sketchup.set_status_text('Revert corner: sharp edge restored.', SB_PROMPT)
      true
    end

    def self.pos(v)
      v.position.to_a
    end

    def self.plane_of(face)
      [V.norm(face.normal.to_a), pos(face.vertices[0])]
    end

    # Finds the four neighbour faces and the sharp edge end points.
    def self.analyse(faces)
      fset = {}
      faces.each { |f| fset[f] = true }
      bedges = faces.flat_map(&:edges).uniq.select { |e| e.faces.count { |f| fset[f] } == 1 }
      raise Error, 'the selection has no outline.' if bedges.empty?
      unless bedges.all? { |e| e.faces.size == 2 }
        raise Error, 'the surface outline must border exactly one other face along every edge.'
      end

      # Outline as one ordered loop of vertices.
      at = Hash.new { |h, k| h[k] = [] }
      bedges.each { |e| e.vertices.each { |v| at[v] << e } }
      unless at.values.all? { |l| l.size == 2 }
        raise Error, 'not recognised as a simple rounded/bevelled edge (the outline is not a simple loop).'
      end
      e0 = bedges.first
      verts = [e0.start]
      edges = []
      e = e0
      v = e0.start
      loop do
        edges << e
        v = e.other_vertex(v)
        break if v == verts[0]
        verts << v
        e = (at[v] - [e]).first
      end
      if edges.size != bedges.size
        raise Error, 'not recognised as a simple rounded/bevelled edge (the outline has more than one loop).'
      end

      # Runs of consecutive outline edges bordering the same neighbour face.
      nb = edges.map { |x| (x.faces - faces).first }
      n = edges.size
      start = (0...n).find { |i| nb[i] != nb[i - 1] }
      raise Error, 'not recognised as a simple rounded/bevelled edge (only one neighbour face).' unless start
      runs = []
      (0...n).each do |k|
        i = (start + k) % n
        if runs.empty? || runs.last[:face] != nb[i]
          runs << { :face => nb[i], :verts => [verts[i]] }
        end
        runs.last[:verts] << verts[(i + 1) % n]
      end
      m = runs.size
      if m < 4
        raise Error, "not recognised as a simple rounded/bevelled edge (it touches only #{m} faces around its outline)."
      end

      # Two side runs (flat faces along the strip) and the runs between them
      # form the two ends. Prefer the longest pair of sides.
      surf_pts = faces.flat_map(&:vertices).uniq.map { |x| pos(x) }
      centre = V.avg(surf_pts)
      best = nil
      (0...m).each do |i|
        ((i + 2)...m).each do |j|
          next if i == 0 && j == m - 1
          sa = runs[i]
          sb = runs[j]
          next if sa[:face] == sb[:face]
          end_a = runs[(i + 1)...j]
          end_b = runs[(j + 1)...m] + runs[0...i]
          next if (end_a + end_b).any? { |r| r[:face] == sa[:face] || r[:face] == sb[:face] }
          # Side faces must meet at a real angle (not neighbouring segments of
          # a curved surface, e.g. when only part of it is selected).
          na = plane_of(sa[:face])[0]
          nb2 = plane_of(sb[:face])[0]
          next if V.dot(na, nb2) > Math.cos(MIN_SIDE_ANGLE * Math::PI / 180)
          line = plane_plane(plane_of(sa[:face]), plane_of(sb[:face]))
          next unless line
          width = sa[:verts].map { |x| sb[:verts].map { |y| V.dist(pos(x), pos(y)) }.min }.max
          far = surf_pts.map { |q| line_dist(q, line) }.max
          # The sharp edge must lie close to the surface.
          next if far > 3.0 * width + 1e-6
          ea = end_info(end_a, line, width, surf_pts, centre)
          eb = end_info(end_b, line, width, surf_pts, centre)
          next unless ea && eb && V.dist(ea[:p], eb[:p]) > 1e-6
          score = run_length(sa) + run_length(sb)
          cand = { :sides => [sa, sb], :ends => [ea, eb], :score => score, :far => far }
          if best.nil? || score > best[:score] + 1e-9 || ((score - best[:score]).abs <= 1e-9 && far < best[:far])
            best = cand
          end
        end
      end
      unless best
        raise Error, 'not recognised as a simple rounded/bevelled edge (no sharp edge found between its ' \
                     'side faces; select the whole rounded surface).'
      end
      best
    end

    def self.run_length(r)
      vs = r[:verts]
      (0...vs.size - 1).inject(0.0) { |acc, k| acc + V.dist(pos(vs[k]), pos(vs[k + 1])) }
    end

    # How one end of the strip is closed. :face - a single flat end face is
    # extended to the sharp edge's end point (simple case); :cap - the end
    # meets other rounded/bevelled geometry, which stays: a small flat cap
    # closes the gap between the sharp edge and the strip's end outline.
    def self.end_info(end_runs, line, width, _surf_pts, centre)
      chain = end_runs.first[:verts] + end_runs[1..-1].flat_map { |r| r[:verts][1..-1] }
      cpts = chain.map { |x| pos(x) }
      o, d = line
      tc = V.dot(V.sub(centre, o), d)
      offs = cpts.map { |q| V.dot(V.sub(q, o), d) - tc }
      side = offs.inject(:+) >= 0 ? 1.0 : -1.0
      reach = offs.map(&:abs).max
      near = lambda { |q| cpts.map { |x| V.dist(x, q) }.min <= 2.0 * width + 1e-6 }
      if end_runs.size == 1
        q = line_plane(line, plane_of(end_runs[0][:face]))
        # A real end face lies beyond this end of the strip, close to it (a
        # neighbouring strip's plane crosses the line far away). A slanted
        # end face: the end outline itself spreads along the line, and the
        # sharp edge's end point may lie within that spread.
        spread = offs.max - offs.min
        if q && near.call(q) && (V.dot(V.sub(q, o), d) - tc) * side >= reach - spread - 1e-6 * (1 + width)
          return { :type => :face, :run => end_runs[0], :p => q, :chain => chain }
        end
      end
      nrm = V.newell(cpts)
      if cpts.size < 3 || V.len(nrm) < 1e-9 * (1 + width * width)
        mid = V.avg(cpts)
        q = V.add(o, V.mul(d, V.dot(V.sub(mid, o), d)))
      else
        nrm = V.norm(nrm)
        dev = cpts.map { |x| V.dot(V.sub(x, cpts[0]), nrm).abs }.max
        return nil if dev > 1e-6 * (1 + width) # end outline not flat: unclear
        q = line_plane(line, [nrm, cpts[0]])
      end
      return nil unless q && near.call(q)
      { :type => :cap, :p => q, :chain => chain }
    end

    # Intersection line of two planes [normal, point]: [point, unit dir].
    def self.plane_plane(a, b)
      d = V.cross(a[0], b[0])
      return nil if V.len(d) < 1e-6
      d = V.norm(d)
      # Point on both planes: solve with the third direction d.
      n1, p1 = a
      n2, p2 = b
      h1 = V.dot(n1, p1)
      h2 = V.dot(n2, p2)
      c = V.dot(n1, n2)
      den = 1 - c * c
      c1 = (h1 - h2 * c) / den
      c2 = (h2 - h1 * c) / den
      [V.add(V.mul(n1, c1), V.mul(n2, c2)), d]
    end

    def self.line_plane(line, plane)
      o, d = line
      n, p = plane
      den = V.dot(n, d)
      return nil if den.abs < 1e-6
      t = V.dot(n, V.sub(p, o)) / den
      V.add(o, V.mul(d, t))
    end

    def self.line_dist(p, line)
      o, d = line
      w = V.sub(p, o)
      V.len(V.sub(w, V.mul(d, V.dot(w, d))))
    end

    # New loops for a neighbour face: its outline run replaced by pts.
    def self.new_loops(face, run_verts, pts)
      loops = [face.outer_loop] + face.loops.reject(&:outer?)
      done = false
      res = loops.map do |lp|
        vs = lp.vertices
        out = replace_run(vs, run_verts, pts)
        if out
          done = true
          out
        else
          vs.map { |x| pos(x) }
        end
      end
      raise Error, 'unexpected face outline.' unless done
      res
    end

    # Replaces the consecutive vertices run (forward or backward, cyclic) in
    # vs by the points pts (given in run order). nil if the run is absent.
    def self.replace_run(vs, run, pts)
      n = vs.size
      k = run.size
      [1, -1].each do |dir|
        i0 = vs.index(run[0])
        next unless i0
        ok = (0...k).all? { |j| vs[(i0 + dir * j) % n] == run[j] }
        next unless ok
        keep = []
        idx = (i0 + dir * (k - 1)) % n
        (n - k).times do |j|
          keep << pos(vs[(idx + dir * (j + 1)) % n])
        end
        # keep runs from after the run end back to before its start
        seq = pts + keep
        return dir == 1 ? seq : seq.reverse
      end
      nil
    end

    def self.apply(ents, faces, plan)
      sa, sb = plan[:sides]
      ea, eb = plan[:ends]
      p1 = ea[:p]
      p2 = eb[:p]
      # Outline order: side a ends at end a, side b runs from end a to end b.
      ra = []
      ra << pos(sa[:verts].first) if eb[:type] == :cap
      ra << p2 << p1
      ra << pos(sa[:verts].last) if ea[:type] == :cap
      rb = []
      rb << pos(sb[:verts].first) if ea[:type] == :cap
      rb << p1 << p2
      rb << pos(sb[:verts].last) if eb[:type] == :cap
      repl = { sa[:face] => [sa[:verts], ra], sb[:face] => [sb[:verts], rb] }
      caps = []
      [[ea, p1], [eb, p2]].each do |info, q|
        if info[:type] == :face
          repl[info[:run][:face]] = [info[:run][:verts], [q]]
        else
          caps << [q] + info[:chain].map { |x| pos(x) }
        end
      end
      data = {}
      repl.each do |f, (run, pts)|
        loops = new_loops(f, run, pts)
        check_loop(loops[0], plane_of(f))
        data[f] = { :loops => loops, :material => f.material, :back_material => f.back_material,
                    :layer => f.layer, :normal => f.normal.to_a }
      end
      caps.each { |pts| check_loop(pts, [V.norm(V.newell(pts)), pts[0]]) }
      centre = V.avg(faces.flat_map(&:vertices).uniq.map { |x| pos(x) })
      src = data[sa[:face]]

      group = {}
      (faces + repl.keys).each { |f| group[f] = true }
      old_edges = (faces + repl.keys).flat_map(&:edges).uniq
      # Edges only used inside the rebuilt area are removed too (avoids
      # leftover split points on the extended edges).
      inner = old_edges.select { |e| e.faces.all? { |f| group[f] } }
      ents.erase_entities((faces + repl.keys + inner).select(&:valid?))

      gp = lambda { |a| Geom::Point3d.new(a[0], a[1], a[2]) }
      repl.each_key do |f|
        d = data[f]
        nf = Bridge.add_face(ents, d[:loops][0].map(&gp))
        raise Error, 'a face could not be rebuilt.' unless nf
        nf.reverse! if nf.normal.dot(Geom::Vector3d.new(*d[:normal])) < 0
        copy_attrs(nf, d)
        d[:loops][1..-1].each do |lp|
          hole = Bridge.add_face(ents, lp.map(&gp))
          hole.erase! if hole && hole.valid? && hole != nf
        end
      end
      caps.each do |pts|
        cf = Bridge.add_face(ents, pts.map(&gp))
        raise Error, 'an end cap could not be created.' unless cf
        # Facing away from the removed surface (outward at the strip end).
        cf.reverse! if cf.normal.dot(Geom::Vector3d.new(*V.sub(pts[0], centre))) < 0
        copy_attrs(cf, src)
      end
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? }
    end

    def self.copy_attrs(f, d)
      f.material = d[:material] if d[:material]
      f.back_material = d[:back_material] if d[:back_material]
      f.layer = d[:layer] if d[:layer]
    end

    # The rebuilt outline must stay planar and must not cross itself.
    def self.check_loop(pts, plane)
      n, o = plane
      size = pts.map { |p| V.dist(p, o) }.max
      if pts.any? { |p| V.dot(V.sub(p, o), n).abs > 1e-6 * (1 + size) }
        raise Error, 'not recognised as a simple rounded/bevelled edge (rebuilt face would not be flat).'
      end
      ax = n.map(&:abs)
      keep = [0, 1, 2] - [ax.index(ax.max)]
      p2 = pts.map { |p| p.values_at(*keep) }
      m = p2.size
      orient = lambda { |a, b, c| (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) }
      m.times do |i|
        a = p2[i]
        b = p2[(i + 1) % m]
        ((i + 2)...m).each do |j|
          next if i == 0 && j == m - 1
          c = p2[j]
          d = p2[(j + 1) % m]
          next unless orient.call(c, d, a) * orient.call(c, d, b) < -1e-12
          next unless orient.call(a, b, c) * orient.call(a, b, d) < -1e-12
          raise Error, 'not recognised as a simple rounded/bevelled edge (rebuilt face would cross itself).'
        end
      end
    end
  end
end
