# Simple Corners - revert rounded or bevelled edges to sharp edges, from the
# geometry alone (no stored data needed).
#
# The selected faces are split into separate surfaces; each is reverted on
# its own, all in one undo step:
#   - Resharpen extends all the faces around the surface until they meet
#     again (single fillets, connected fillets, rounded corners, whole
#     rounded solids);
#   - when only part of a smooth surface is selected: a single strip (a
#     fillet or chamfer along one edge) with two flat side faces; the side
#     faces are extended until they meet. Each end is either one flat end
#     face, which is extended to the edge's end point, or other rounded or
#     bevelled geometry, which stays: a small flat cap closes the gap.
# Anything unclear is reported as not recognised and that surface does not
# change.
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
    NAME = 'Revert to sharp edge'.freeze

    # Reverts the selected surfaces. Returns true when the model changed.
    def self.run(model = Sketchup.active_model)
      ctx = SimpleCorners.context_parent(model)
      faces = model.selection.to_a.grep(Sketchup::Face).select { |f| f.parent == ctx }
      begin
        raise Error, 'select the rounded or bevelled surface first (click it).' if faces.empty?
        done, failed = revert_all(model, by_network(surfaces(faces)))
      rescue Error => err
        UI.messagebox("#{NAME}: #{err.message}")
        return false
      rescue StandardError => err
        SimpleCorners.log_error(NAME, err, true)
        UI.messagebox("#{NAME} failed: #{err.message}\n(details in Window > Ruby Console)")
        return false
      end
      model.selection.clear
      if failed.empty?
        Sketchup.set_status_text("#{NAME}: #{done == 1 ? 'sharp edges restored' : "#{done} surfaces reverted"}.", SB_PROMPT)
      else
        UI.messagebox("#{NAME}: #{done} of #{done + failed.size} surfaces reverted. The others were not " \
                      "recognised, e.g.: #{failed.first}")
      end
      true
    end

    # Groups of faces connected by edges or corners.
    def self.surfaces(faces)
      fset = {}
      faces.each { |f| fset[f] = true }
      seen = {}
      out = []
      faces.each do |f0|
        next if seen[f0]
        seen[f0] = true
        group = []
        todo = [f0]
        until todo.empty?
          f = todo.pop
          group << f
          f.vertices.each do |v|
            v.faces.each do |g|
              next if !fset[g] || seen[g]
              seen[g] = true
              todo << g
            end
          end
        end
        out << group
      end
      out
    end

    # Selected surfaces of one rounded network are reverted together (the
    # network is rebuilt once, knowing everything that is selected).
    def self.by_network(groups)
      owner = {}
      merged = []
      groups.each do |g|
        net = network_of(g)
        hit = net.map { |f| owner[f] }.compact.uniq
        into = hit.empty? ? [] : hit.inject([]) { |acc, i| acc + merged[i] }
        hit.each { |i| merged[i] = [] }
        merged << into + g
        (net + into).each { |f| owner[f] = merged.size - 1 }
      end
      merged.reject(&:empty?)
    end

    # Reverts each surface; surfaces that are not recognised stay as they
    # are. Returns [number reverted, messages of the others]. Raises Error
    # when none was reverted (nothing changes).
    def self.revert_all(model, groups)
      done = 0
      failed = []
      model.start_operation('Revert to Sharp Edge', true)
      begin
        groups.each do |faces|
          faces = faces.select(&:valid?)
          next if faces.empty?
          job = begin
            plan(faces)
          rescue Error => e
            failed << e.message
            next
          end
          commit(model.active_entities, job)
          done += 1
        end
      rescue StandardError
        model.abort_operation
        raise
      end
      if done == 0
        model.abort_operation
        raise Error, failed.first
      end
      model.commit_operation
      [done, failed]
    end

    # What to do with one surface (nothing in the model changes yet):
    #   - part of a rounded network: the whole network is reverted, then its
    #     edges whose rounding was not selected are rounded again as they
    #     were (radius measured, same mode and segments);
    #   - else the faces around the surface extended until they meet (fully
    #     checked);
    #   - else, for part of a smooth surface, the single strip method.
    def self.plan(faces)
      net = network_of(faces)
      if net.size > faces.size
        begin
          return prepare_partial(faces, net)
        rescue Error, Resharpen::Error
          nil # try the selection on its own
        end
      end
      begin
        return { :kind => :network, :faces => faces, :data => prepare_network(faces) }
      rescue Resharpen::Error => e1
        begin
          strip = analyse(faces)
          return { :kind => :strip, :faces => faces, :data => prepare(faces, strip) }
        rescue Error => e2
          raise Error, (e1.message =~ /only part of a smooth/ ? e2.message : e1.message)
        end
      end
    end

    def self.commit(ents, job)
      case job[:kind]
      when :strip then apply(ents, job[:faces], job[:data])
      when :partial then apply_partial(ents, job)
      else apply_network(ents, job[:faces], job[:data])
      end
    end

    def self.op_of(f)
      f.get_attribute(Bridge::DICT, 'op')
    end

    # The rounded network the faces belong to: grown across soft edges, and
    # across hard edges (e.g. mitre ridges) into faces made by the same
    # rounding operation as the selected faces.
    def self.network_of(faces)
      ops = {}
      faces.each { |f| o = op_of(f); ops[o] = true if o }
      seen = {}
      faces.each { |f| seen[f] = true }
      todo = faces.dup
      until todo.empty?
        f = todo.pop
        f.edges.each do |e|
          e.faces.each do |g|
            next if seen[g]
            o = op_of(g)
            next unless o ? ops[o] : e.soft?
            seen[g] = true
            todo << g
          end
        end
      end
      seen.keys
    end

    # Part of a network selected: plan the revert of the whole network and
    # which of its edges get rounded again (those whose rounding was mostly
    # not selected, by area), with their measured radius.
    def self.prepare_partial(sel, net)
      rebuild = prepare_network(net)
      # edges of the rebuilt faces that were rounded: their two faces share
      # no edge before the revert (a sharp edge always keeps a piece, even
      # when roundings next to it took both of its ends)
      cnt = Hash.new(0)
      ends = {}
      planes = {}
      olds = {}
      rebuild.each do |d|
        d[:loops].each do |lp|
          lp.each_index do |i|
            a = lp[i]
            b = lp[(i + 1) % lp.size]
            k = [Bridge.pkey(Geom::Point3d.new(*a)), Bridge.pkey(Geom::Point3d.new(*b))].sort
            cnt[k] += 1
            ends[k] = [a, b]
            (planes[k] ||= []) << [V.norm(d[:normal]), lp[0]]
            (olds[k] ||= []) << d[:old]
          end
        end
      end
      cnt.keys.each do |k|
        next unless cnt[k] == 2
        f, g = olds[k]
        cnt[k] = 0 unless (f.edges & g.edges).empty?
      end
      keys = cnt.keys.select { |k| cnt[k] == 2 }
      segs = keys.map { |k| ends[k] }
      sides = keys.map { |k| planes[k] }
      raise Error, 'not recognised (no rounded edge found).' if segs.empty?
      # each face of the network belongs to the nearest of those edges
      sset = {}
      sel.each { |f| sset[f] = true }
      owned = Hash.new { |h, i| h[i] = [] }
      net.each do |f|
        c = V.avg(f.vertices.map { |v| pos(v) })
        i = (0...segs.size).min_by { |j| seg_dist(c, segs[j][0], segs[j][1]) }
        owned[i] << f
      end
      # selected share of the edge's surface, by area (small corner faces
      # count little)
      frac = lambda do |i|
        total = owned[i].inject(0.0) { |s2, f| s2 + f.area }
        total > 0 ? owned[i].inject(0.0) { |s2, f| s2 + (sset[f] ? f.area : 0.0) } / total : 0.0
      end
      sharp = owned.keys.select { |i| frac.call(i) >= 0.5 }
      sharp = [owned.keys.max_by { |i| frac.call(i) }] if sharp.empty?
      again = owned.keys - sharp
      stored = lambda do |fs|
        rs = fs.map { |f| f.get_attribute(Bridge::DICT, 'radius') }.compact
        rs.empty? ? nil : rs.max_by { |x| rs.count(x) }.to_f
      end
      reround = again.map do |i|
        [segs[i][0], segs[i][1], measured_offset(segs[i], owned[i], sides[i], stored.call(owned[i]))]
      end
      modes = Hash.new(0)
      net.each { |f| m = f.get_attribute(Bridge::DICT, 'mode'); modes[m.to_sym] += 1 if m }
      tagged = lambda do |key|
        vals = net.map { |f| f.get_attribute(Bridge::DICT, key) }.compact
        vals.empty? ? nil : vals.max_by { |x| vals.count(x) }
      end
      counts = again.map { |i| segment_count(segs[i], owned[i]) }.compact
      counts = [tagged.call('segments').to_i] if tagged.call('segments')
      mode = modes.empty? ? (counts.max.to_i <= 1 ? :bevel : :round) : modes.max_by { |_m, n| n }[0]
      # smoothed: most edges inside the network are soft (without smoothing
      # only the diagonals of split faces are)
      nset = {}
      net.each { |f| nset[f] = true }
      inner = net.flat_map(&:edges).compact.uniq.select { |e| e.faces.all? { |g| nset[g] } }
      smooth = inner.count(&:soft?) * 2 > inner.size
      smooth = tagged.call('smooth') unless tagged.call('smooth').nil?
      { :kind => :partial, :faces => net, :data => rebuild, :reround => reround, :mode => mode,
        :segments => counts.empty? ? Settings.segments : counts.max, :smooth => smooth }
    end

    def self.seg_dist(p, a, b)
      ab = V.sub(b, a)
      l2 = V.dot(ab, ab)
      t = l2 > 0 ? [[V.dot(V.sub(p, a), ab) / l2, 0.0].max, 1.0].min : 0.0
      V.dist(p, V.add(a, V.mul(ab, t)))
    end

    # Radius of a rounded edge: the largest distance from the sharp edge at
    # which its surface leaves either of the two faces (near corners the
    # boundary can come a little closer). The radius the tool stored on the
    # faces is used unless the geometry is clearly smaller (it was reduced).
    def self.measured_offset(seg, faces, planes, stored = nil)
      a, b = seg
      ab = V.sub(b, a)
      l2 = V.dot(ab, ab)
      dist = lambda { |q| V.len(V.cross(V.sub(q, a), ab)) / Math.sqrt(l2) }
      cand = faces.flat_map(&:vertices).uniq.map { |v| pos(v) } + crossings(seg, faces)
      cand = cand.select { |q| t = V.dot(V.sub(q, a), ab) / l2; t > -0.25 && t < 1.25 }
      size = Math.sqrt(l2) + cand.map { |q| dist.call(q) }.max.to_f
      on = cand.select { |q| planes.any? { |n, o| V.dot(V.sub(q, o), n).abs <= 1e-6 * (1 + size) } }
      m = (on.empty? ? cand : on).map { |q| dist.call(q) }.max
      # (larger than stored: faces of a neighbouring edge were counted)
      return stored if stored && (m.nil? || m >= 0.98 * stored)
      m
    end

    # Points where the faces' edges cross the plane through the middle of
    # the edge, square to it.
    def self.crossings(seg, faces)
      a, b = seg
      n = V.norm(V.sub(b, a))
      mid = V.avg([a, b])
      out = []
      faces.flat_map(&:edges).compact.uniq.each do |e|
        p = pos(e.start)
        q = pos(e.end)
        sp = V.dot(V.sub(p, mid), n)
        sq = V.dot(V.sub(q, mid), n)
        next if sp * sq > 0 || (sp - sq).abs < 1e-12
        out << V.add(p, V.mul(V.sub(q, p), sp / (sp - sq)))
      end
      out
    end

    # Segments of a rounded edge (when the faces do not say): rows of faces
    # across its middle. Halves of a split row face almost the same way;
    # neighbouring rows differ by a whole step.
    def self.segment_count(seg, faces)
      a, b = seg
      n = V.norm(V.sub(b, a))
      mid = V.avg([a, b])
      across = faces.select do |f|
        s2 = f.vertices.map { |v| V.dot(V.sub(pos(v), mid), n) }
        s2.min < 0 && s2.max > 0
      end
      return nil if across.empty?
      ns = across.map { |f| f.normal.to_a }
      u = V.sub(ns[0], V.mul(n, V.dot(ns[0], n)))
      return 1 if V.len(u) < 1e-9
      u = V.norm(u)
      w = V.cross(n, u)
      angs = ns.map { |x| Math.atan2(V.dot(x, w), V.dot(x, u)) }.sort
      gaps = (0...angs.size - 1).map { |i| angs[i + 1] - angs[i] }
      return 1 if gaps.empty? || gaps.max < 1e-6
      big = gaps.max * 0.35
      1 + gaps.count { |g| g > big }
    end

    def self.apply_partial(ents, job)
      newf = apply_network(ents, job[:faces], job[:data])
      return if job[:reround].empty?
      at = {}
      newf.select(&:valid?).flat_map(&:vertices).uniq.each { |v| at[Bridge.pkey(v.position)] = v }
      offsets = {}
      job[:reround].each do |a, b, d|
        va = at[Bridge.pkey(Geom::Point3d.new(*a))]
        vb = at[Bridge.pkey(Geom::Point3d.new(*b))]
        e = va && vb && va.common_edge(vb)
        raise Error, 'an edge to round again was not found.' unless e
        offsets[e] = d
      end
      op_id = format('%d-%06d', Time.now.to_i, rand(1_000_000))
      opts = { :mode => job[:mode], :offset => offsets.values.max, :segments => job[:segments],
               :smooth => job[:smooth], :edge_offsets => offsets, :op_id => op_id }
      begin
        Bridge.process(ents, offsets.keys, opts)
      rescue Core::Error, Bridge::Error => err
        raise Error, "the other edges could not be rounded again (#{err.message})"
      end
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

    # Everything the strip revert needs, checked (nothing changes yet).
    def self.prepare(faces, plan)
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
      (data.values.flat_map { |d| d[:loops] } + caps).each { |lp| check_points(lp) }
      predict_closed(faces + repl.keys, data.values.flat_map { |d| d[:loops] } + caps)
      { :repl => repl, :caps => caps, :data => data, :src => data[sa[:face]] }
    end

    # Before anything changes: the new faces (loops of points) replacing
    # the removed faces must close up with the faces that stay (every new
    # edge between exactly two faces, unless it was open before).
    def self.predict_closed(removed, loops)
      gone = {}
      removed.each { |f| gone[f] = true }
      key = lambda { |a, b| [Bridge.pkey(a), Bridge.pkey(b)].sort }
      cnt = Hash.new(0)
      loops.each do |lp|
        lp.each_index do |i|
          a = lp[i]
          b = lp[(i + 1) % lp.size]
          cnt[key.call(Geom::Point3d.new(*a), Geom::Point3d.new(*b))] += 1
        end
      end
      open = {}
      removed.flat_map(&:vertices).uniq.flat_map(&:edges).uniq.each do |e|
        k = key.call(e.start.position, e.end.position)
        open[k] = true if e.faces.size == 1
        next unless cnt.key?(k)
        cnt[k] += e.faces.count { |f| !gone[f] }
      end
      cnt.each do |k, c|
        next if c == 2 || (c == 1 && open[k])
        raise Error, 'not recognised (the rebuilt faces would not close up).'
      end
    end

    # A face SketchUp can create: at least three points, none closer than
    # its tolerance to another.
    def self.check_points(lp)
      n = lp.size
      bad = n < 3
      n.times do |i|
        ((i + 1)...n).each { |j| bad ||= V.dist(lp[i], lp[j]) <= Bridge::MIN_DIST }
      end
      raise Error, 'not recognised (a rebuilt face would be too small).' if bad
    end

    # Every edge of the rebuilt faces must have faces on both sides (unless
    # it had only one before).
    def self.check_closed(new_faces, border)
      new_faces.select(&:valid?).flat_map(&:edges).uniq.each do |e|
        next if e.faces.size >= 2 || border[ekey(e.start.position, e.end.position)]
        raise Error, 'the rebuilt faces do not close up.'
      end
    end

    def self.border_keys(faces)
      border = {}
      faces.each do |f|
        f.edges.each { |e| border[ekey(e.start.position, e.end.position)] = true if e.faces.size == 1 }
      end
      border
    end

    def self.apply(ents, faces, prep)
      repl = prep[:repl]
      caps = prep[:caps]
      data = prep[:data]
      src = prep[:src]
      centre = V.avg(faces.flat_map(&:vertices).uniq.map { |x| pos(x) })

      border = border_keys(faces + repl.keys)
      created = []
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
        created << nf
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
        created << cf
      end
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? }
      check_closed(created, border)
    end

    # Reverts a whole network (Resharpen): the faces around the surface get
    # new outlines. Nothing changes yet.
    def self.prepare_network(faces)
      fset = {}
      faces.each { |f| fset[f] = true }
      around = faces.flat_map(&:vertices).uniq.flat_map(&:faces).uniq.reject { |f| fset[f] }
      local = faces + around
      idx = {}
      local.each_with_index { |f, i| idx[f] = i }
      vid = {}
      pts = []
      id = lambda { |v| vid[v] ||= (pts << pos(v); pts.size - 1) }
      fdata = local.map do |f|
        n = f.normal.to_a
        loops = [f.outer_loop] + f.loops.reject(&:outer?)
        ls = loops.each_with_index.map do |lp, li|
          ids = lp.vertices.map { |v| id.call(v) }
          s = V.dot(V.newell(ids.map { |i| pts[i] }), n)
          ids.reverse! if (li == 0 && s < 0) || (li > 0 && s > 0)
          ids
        end
        soft = []
        f.edges.each do |e|
          next unless e.soft?
          e.faces.each { |g| soft << (idx[g] || -1) unless g == f }
        end
        { :loops => ls, :normal => n, :soft => soft.uniq }
      end
      open = []
      local.each do |f|
        f.edges.each { |e| open << [id.call(e.start), id.call(e.end)] if e.faces.size == 1 }
      end
      res = Resharpen.solve(pts, fdata, faces.map { |f| idx[f] }, open, Bridge::MIN_DIST)
      res.each_value { |lps| lps.each { |lp| check_points(lp) } }
      predict_closed(faces + res.keys.map { |fi| local[fi] }, res.values.flatten(1))
      res.map do |fi, lps|
        f = local[fi]
        { :old => f, :loops => lps, :material => f.material, :back_material => f.back_material,
          :layer => f.layer, :normal => f.normal.to_a }
      end
    end

    def self.apply_network(ents, faces, rebuild)
      olds = rebuild.map { |d| d[:old] }
      oset = {}
      olds.each { |f| oset[f] = true }
      # edges between two rebuilt faces get their properties back
      pairs = {}
      border = border_keys(olds)
      olds.each do |f|
        f.edges.each do |e|
          e.faces.each do |g|
            next if g == f || !oset[g]
            pairs[[f, g].sort_by(&:object_id)] = Bridge.edge_attrs(e)
          end
        end
      end
      old_edges = (faces + olds).flat_map(&:edges).uniq
      ents.erase_entities((faces + olds).select(&:valid?))
      old_edges.each { |e| e.erase! if e.valid? && e.faces.empty? }

      gp = lambda { |a| Geom::Point3d.new(a[0], a[1], a[2]) }
      newf = {}
      rebuild.each do |d|
        nf = Bridge.add_face(ents, d[:loops][0].map(&gp))
        raise Error, 'a face could not be rebuilt.' unless nf
        nf.reverse! if nf.normal.dot(Geom::Vector3d.new(*d[:normal])) < 0
        copy_attrs(nf, d)
        d[:loops][1..-1].each do |lp|
          hole = Bridge.add_face(ents, lp.map(&gp))
          hole.erase! if hole && hole.valid? && hole != nf
        end
        newf[d[:old]] = nf
      end
      pairs.each do |(a, b), at|
        na = newf[a]
        nb = newf[b]
        next unless na && nb && na.valid? && nb.valid?
        (na.edges & nb.edges).each do |e|
          e.soft = at[:soft]
          e.smooth = at[:smooth]
          e.hidden = at[:hidden]
        end
      end
      check_closed(newf.values, border)
      newf.values
    end

    def self.ekey(a, b)
      [Bridge.pkey(a), Bridge.pkey(b)].sort
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
