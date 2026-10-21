# Simple Corners - interactive tool (one instance per mode).
#
# Works like SketchUp's own tools (Circle, Offset):
#   1. Pick: what is selected (with the Select tool or here) is processed.
#      If nothing is selected, the first click picks the edge, face or
#      group under the cursor. Ctrl+click adds, Shift+click toggles,
#      Ctrl+Shift+click removes (Option instead of Ctrl on Mac).
#   2. Radius: the first click is point 1. Move to see the result live,
#      click point 2: the distance between both points is the radius
#      (or the bevel offset).
#   Keyboard: before the first click, a number is the segment count
#   (like the sides of a circle, also "8s"); after it, a length is the
#   radius and applies at once. Enter applies with the last radius.
#   Esc steps back. Click-drag-release works too. After applying (or
#   failing) the Select tool returns.
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

module SimpleCorners
  class CornerTool
    SEL_COLOR = Sketchup::Color.new(255, 128, 0)
    SEL_FILL = Sketchup::Color.new(255, 140, 0, 90)
    HOVER_COLOR = Sketchup::Color.new(0, 150, 255)
    HOVER_WIDTH = 10 # hovered edge: twice the selection lines
    # Hovered face or group: a thin outline, so it does not look like an edge.
    HOVER_FACE_WIDTH = 3
    HARD_COLOR = Sketchup::Color.new(210, 0, 0)
    SOFT_COLOR = Sketchup::Color.new(245, 140, 140)

    @cursors = {}
    class << self
      attr_reader :cursors
    end

    def initialize(mode)
      @mode = mode
    end

    # --- SketchUp tool callbacks ----------------------------------------

    def activate
      @model = Sketchup.active_model
      @ip = Sketchup::InputPoint.new
      @ip1 = Sketchup::InputPoint.new
      @state = :select
      @hover = nil
      @p1 = nil
      @radius = nil
      @preview = nil
      @res_key = nil
      @sel_key = nil
      @res_key = nil
      @active = true
      refresh_preview
      update_ui
      @model.active_view.invalidate
    end

    def deactivate(view)
      @active = false
      UI.stop_timer(@timer) if @timer
      @timer = nil
      view.invalidate
    end

    def suspend(view)
      view.invalidate
    end

    def resume(view)
      update_ui
      view.invalidate
    end

    def enableVCB?
      true
    end

    def onSetCursor
      id = cursor_id
      UI.set_cursor(id) if id && id > 0
    end

    def onCancel(_reason, view)
      if @state == :radius
        to_select_state
      else
        @model.selection.clear
        refresh_preview
      end
      update_ui
      view.invalidate
    end

    def onMouseMove(_flags, x, y, view)
      if @state == :radius
        @ip.pick(view, x, y, @ip1)
        @radius = @p1.distance(@ip.position).to_f
        view.tooltip = @ip.tooltip if @ip.valid?
        refresh_preview(@radius)
      else
        @ip.pick(view, x, y)
        @hover = entity_at(view, x, y)
        view.tooltip = hover_tip
        refresh_preview
      end
      update_ui
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      if @state == :radius
        @down_xy = nil
        @ip.pick(view, x, y, @ip1)
        r = @p1.distance(@ip.position).to_f
        if r <= 1e-6
          UI.beep
          return
        end
        finish(r)
        return
      end

      add = (flags & COPY_MODIFIER_MASK) != 0
      toggle = (flags & CONSTRAIN_MODIFIER_MASK) != 0
      ent = entity_at(view, x, y)
      if add || toggle
        change_selection(ent, add, toggle)
        refresh_preview
        update_ui
        view.invalidate
        return
      end
      if SimpleCorners.targets(@model).empty?
        unless ent
          UI.beep
          return
        end
        @model.selection.add(ent)
      end
      @ip.pick(view, x, y)
      @ip1.copy!(@ip)
      @p1 = @ip.position
      @down_xy = [x, y]
      @state = :radius
      @radius = nil
      update_ui
      view.invalidate
    end

    # Click-drag-release also works: releasing away from point 1 sets point 2.
    def onLButtonUp(_flags, x, y, view)
      return unless @state == :radius && @down_xy
      dx = x - @down_xy[0]
      dy = y - @down_xy[1]
      @down_xy = nil
      return if dx * dx + dy * dy < 100
      onLButtonDown(0, x, y, view)
    end

    def onReturn(_view)
      if @state == :radius && @radius && @radius > 1e-6
        finish(@radius)
      elsif !SimpleCorners.targets(@model).empty?
        finish(Settings.radius)
      else
        UI.beep
      end
    end

    def onUserText(text, view)
      t = text.strip
      if @mode != :bevel && t =~ /\A(\d+)\s*(s?)\z/i && (@state == :select || !$2.empty?)
        n = $1.to_i
        if n < 1 || n > 64
          UI.beep
          Sketchup.set_status_text('Segments must be between 1 and 64.', SB_PROMPT)
          return
        end
        Settings.segments = n
        @res_key = nil
        refresh_preview(@state == :radius ? @radius : nil)
        update_ui
        view.invalidate
        return
      end
      r = begin
        t.to_l.to_f
      rescue ArgumentError
        nil
      end
      if r.nil? || !r.finite? || r <= 0
        UI.beep
        Sketchup.set_status_text("Invalid value: #{t}", SB_PROMPT)
        return
      end
      if SimpleCorners.targets(@model).empty?
        Settings.radius = r
        update_ui
        Sketchup.set_status_text("#{name}: radius set to #{r.to_l}. Pick the edges to process.", SB_PROMPT)
        return
      end
      finish(r)
    end

    def getMenu(menu, _flags = nil, _x = nil, _y = nil, _view = nil)
      view = @model.active_view
      r = (@state == :radius && @radius ? @radius : Settings.radius).to_l
      menu.add_item("Apply #{name} (#{r})") { onReturn(view) }
      menu.add_separator
      SimpleCorners::MODES.each do |m|
        id = menu.add_item(SimpleCorners::MODE_NAMES[m]) do
          @mode = m
          @res_key = nil
          refresh_preview(@state == :radius ? @radius : nil)
          update_ui
          view.invalidate
        end
        menu.set_validation_proc(id) { m == @mode ? MF_CHECKED : MF_UNCHECKED }
      end
      menu.add_separator
      sid = menu.add_item('Smooth new surfaces') do
        Settings.smooth = !Settings.smooth?
        update_ui
      end
      menu.set_validation_proc(sid) { Settings.smooth? ? MF_CHECKED : MF_UNCHECKED }
      menu.add_item('Radius and segments...') do
        Settings.dialog
        @res_key = nil
        refresh_preview
        update_ui
        view.invalidate
      end
      menu.add_item('Clear selection') do
        @model.selection.clear
        to_select_state
        refresh_preview
        update_ui
        view.invalidate
      end
      true
    end

    def draw(view)
      @lift = lift_vector(view)
      draw_all(view)
    rescue StandardError => err
      # A drawing error must not blank the tool: report it once.
      SimpleCorners.log_error('Drawing', err)
    end

    def draw_all(view)
      pv = @preview
      if pv
        # What is selected: tinted faces, thick edges with end dots, boxes
        # around groups/components.
        unless pv[:tris].empty?
          view.drawing_color = SEL_FILL
          view.draw(GL_TRIANGLES, lifted(pv[:tris]))
        end
        draw_lines(view, pv[:sel], SEL_COLOR, 5)
        draw_lines(view, pv[:boxes], SEL_COLOR, 4)
        view.draw_points(lifted(pv[:ends]), 7, 2, SEL_COLOR) unless pv[:ends].empty?
        unless pv[:error]
          draw_lines(view, pv[:soft], SOFT_COLOR, 1)
          draw_lines(view, pv[:hard], HARD_COLOR, 2)
        end
      end
      draw_hover(view) if @state == :select && @hover && @hover.valid?
      if @state == :radius && @ip.valid?
        view.line_stipple = '-'
        draw_lines(view, [@p1, @ip.position], HARD_COLOR, 2)
        view.line_stipple = ''
        view.draw_points(lifted([@p1]), 8, 2, HARD_COLOR)
      end
      @ip.draw(view) if @ip && @ip.valid? && @ip.display?
    end

    def getExtents
      bb = Geom::BoundingBox.new
      bb.add(@model.bounds)
      if @preview
        bb.add(@preview[:sel]) unless @preview[:sel].empty?
        bb.add(@preview[:tris]) unless @preview[:tris].empty?
        bb.add(@preview[:boxes]) unless @preview[:boxes].empty?
        bb.add(@preview[:hard]) unless @preview[:hard].empty?
      end
      bb.add(@p1) if @p1
      bb
    end

    # --- helpers --------------------------------------------------------------

    def name
      SimpleCorners::MODE_NAMES[@mode]
    end

    def cursor_id
      c = CornerTool.cursors
      unless c.key?(@mode)
        path = SimpleCorners.icon("cursor_#{@mode}")
        c[@mode] = File.exist?(path) ? UI.create_cursor(path, 3, 3) : 0
      end
      c[@mode]
    end

    # Edge, face, group or component under the cursor (open context only).
    def entity_at(view, x, y)
      ph = view.pick_helper
      ph.do_pick(x, y)
      e = ph.best_picked
      return nil unless e
      if e.is_a?(Sketchup::Edge) || e.is_a?(Sketchup::Face)
        e.parent == SimpleCorners.context_parent(@model) ? e : nil
      elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        e
      end
    end

    # Ctrl adds, Shift toggles, Ctrl+Shift removes (like the Select tool).
    def change_selection(ent, add, toggle)
      return UI.beep unless ent
      sel = @model.selection
      if add && toggle
        sel.remove(ent)
      elsif add
        sel.add(ent)
      elsif sel.include?(ent)
        sel.remove(ent)
      else
        sel.add(ent)
      end
    end

    def hover_tip
      return '' unless @hover
      kind = case @hover
             when Sketchup::Edge then 'edge'
             when Sketchup::Face then 'face (all its edges)'
             else 'group (all its edges)'
             end
      sel = @model.selection
      if sel.include?(@hover)
        "Selected #{kind} - Shift+click: deselect"
      elsif SimpleCorners.targets(@model).empty?
        "Click: #{@mode == :bevel ? 'bevel' : 'round'} this #{kind}"
      else
        "Ctrl+click: add this #{kind}"
      end
    end

    def finish(radius)
      SimpleCorners.apply(@mode, radius)
      # Like SketchUp's own tools: back to the Select tool, also on failure.
      @model.select_tool(nil)
    end

    def to_select_state
      @state = :select
      @p1 = nil
      @radius = nil
      refresh_preview
    end

    # Preview caches: the selection drawing is rebuilt only when the
    # selection changes, the result only when radius, segments, mode or
    # smoothing change. Slow results are throttled; a timer computes the
    # last requested radius once the mouse rests.
    THROTTLE = 0.12
    SLOW = 0.04

    # radius nil = last used radius (what Enter would do).
    def refresh_preview(radius = nil, force = false)
      r = radius || Settings.radius
      skey = @model.selection.to_a.map { |e| e.valid? ? e.entityID : 0 }
      if skey != @sel_key
        @sel_key = skey
        @sel_data = SimpleCorners.selection_data(@model)
        @res_key = nil
        @warm = nil
        @last_r = nil
      end
      rkey = [r, Settings.segments, @mode, Settings.smooth?]
      if rkey == @res_key
        compose_preview
        return
      end
      now = Time.now.to_f
      if !force && @last_cost && @last_cost > SLOW && @last_at && now - @last_at < THROTTLE
        schedule_preview(r)
        compose_preview
        return
      end
      warm = @last_r && r >= @last_r && @warm_mode == @mode ? @warm : nil
      t0 = Time.now.to_f
      @result = SimpleCorners.preview_result(@model, @mode, r, warm)
      @last_at = Time.now.to_f
      @last_cost = @last_at - t0
      @warm = @result[:warm]
      @warm_mode = @mode
      @last_r = r
      @res_key = rkey
      compose_preview
    end

    def compose_preview
      @preview = (@sel_data || {}).merge(@result || {})
    end

    def schedule_preview(r)
      @pending_r = r
      return if @timer
      @timer = UI.start_timer(THROTTLE, false) do
        @timer = nil
        next unless @active
        refresh_preview(@pending_r, true)
        update_ui
        @model.active_view.invalidate
      end
    end

    def draw_lines(view, pts, color, width)
      return if pts.nil? || pts.size < 2
      view.line_width = width
      view.drawing_color = color
      view.draw(GL_LINES, lifted(pts))
    end

    # Everything the tool draws lies on existing faces and edges. Moving it
    # a tiny step toward the camera keeps it in front of them; some graphics
    # engines (e.g. the new one in SketchUp 2025) otherwise hide it.
    LIFT = 0.001 # fraction of the distance to the camera

    def lift_vector(view)
      cam = view.respond_to?(:camera) ? view.camera : nil
      return nil unless cam
      { :eye => cam.eye, :dir => cam.direction, :persp => cam.perspective? }
    end

    def lifted(pts)
      l = @lift
      return pts unless l
      pts.map do |p|
        if l[:persp]
          v = p.vector_to(l[:eye])
          len = v.length
          next p if len <= 0
          v.length = len * LIFT
        else
          v = l[:dir].reverse
          v.length = [(p.distance(l[:eye]) * LIFT), 1e-6].max
        end
        p.offset(v)
      end
    end

    def draw_hover(view)
      tr = SimpleCorners.edit_transform(@model)
      pts = []
      case @hover
      when Sketchup::Edge
        pts << @hover.start.position << @hover.end.position
      when Sketchup::Face
        @hover.edges.each { |e| pts << e.start.position << e.end.position }
      else
        return draw_lines(view, SimpleCorners.box_lines(@hover.bounds, tr), HOVER_COLOR, HOVER_FACE_WIDTH)
      end
      width = @hover.is_a?(Sketchup::Edge) ? HOVER_WIDTH : HOVER_FACE_WIDTH
      draw_lines(view, pts.map { |p| p.transform(tr) }, HOVER_COLOR, width)
    end

    def update_ui
      pv = @preview || {}
      n = pv[:edges] || 0
      if @state == :radius
        what = @mode == :bevel ? 'offset' : 'radius'
        msg = "#{name}: click the second point to set the #{what}, or type it. Esc = back."
        label = @mode == :bevel ? 'Offset' : 'Radius'
        value = @radius ? @radius.to_l.to_s : ''
      elsif n == 0
        msg = "#{name}: click an edge, a face or a group to process it " \
              '(Ctrl+click adds, Shift+click toggles).'
        msg += ' Type a number to set the segments.' unless @mode == :bevel
        label, value = vcb_select
      else
        msg = "#{name}: #{n} edge(s). Click two points for the radius, or type it. " \
              "Enter = last radius (#{Settings.radius.to_l}). Ctrl/Shift+click changes the selection. Esc = clear."
        label, value = vcb_select
      end
      msg += "  [#{pv[:error]}]" if pv[:error]
      msg += "  [radius reduced on #{pv[:reduced]} edge(s) to fit]" if pv[:reduced] && pv[:reduced] > 0
      msg += Settings.smooth? ? '  [smooth: on]' : '  [smooth: off]' unless @mode == :bevel
      msg += '  [preview off: large selection]' if pv[:skipped]
      Sketchup.set_status_text(msg, SB_PROMPT)
      Sketchup.set_status_text(label, SB_VCB_LABEL)
      Sketchup.set_status_text(value, SB_VCB_VALUE)
    end

    def vcb_select
      if @mode == :bevel
        ['Offset', Settings.radius.to_l.to_s]
      else
        ['Segments', Settings.segments.to_s]
      end
    end
  end
end
