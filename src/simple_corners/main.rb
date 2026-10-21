# encoding: UTF-8
# Simple Corners - menus, toolbar, settings, selection targets, preview and
# the apply command.
#
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later (see LICENSE.txt)

require 'sketchup.rb'

module SimpleCorners
  PATH = File.dirname(__FILE__).dup.force_encoding('UTF-8')

  require File.join(PATH, 'core.rb')
  require File.join(PATH, 'bridge.rb')
  require File.join(PATH, 'tool.rb')
  require File.join(PATH, 'unround.rb')

  MODES = [:round, :sharp, :bevel].freeze
  MODE_NAMES = { :round => 'Round Edges', :sharp => 'Round Edges, Mitred', :bevel => 'Bevel Edges' }.freeze
  MODE_TIPS = {
    :round => 'Round edges: pick edges, then click two points for the radius. Corners become smooth.',
    :sharp => 'Round edges with sharp corners: pick edges, then click two points for the radius.',
    :bevel => 'Bevel (chamfer) edges: pick edges, then click two points for the offset.'
  }.freeze
  # Above this many edges the live preview is skipped (speed).
  PREVIEW_MAX_EDGES = 2000
  # Fitting steps allowed per preview update (the final apply fits fully).
  PREVIEW_FIT_STEPS = 8
  # Above this many new faces, applying asks first (it can take minutes).
  CONFIRM_FACES = 20_000

  # Persistent parameters (stored in the SketchUp preferences).
  module Settings
    SECTION = 'SimpleCorners'.freeze

    def self.default_radius
      1.cm.to_f
    end

    # Last radius / offset used, in model units (inches).
    def self.radius
      v = Sketchup.read_default(SECTION, 'offset', default_radius).to_f
      v > 0 ? v : default_radius
    end

    def self.radius=(x)
      Sketchup.write_default(SECTION, 'offset', x.to_f)
    end

    def self.segments
      v = Sketchup.read_default(SECTION, 'segments', 6).to_i
      v >= 1 && v <= 64 ? v : 6
    end

    def self.segments=(n)
      Sketchup.write_default(SECTION, 'segments', n.to_i)
    end

    def self.dialog
      res = UI.inputbox(['Radius / offset', 'Segments (1-64, not used by Bevel)'],
                        [radius.to_l, segments], 'Simple Corners')
      return false unless res
      r, segs = res
      if r.to_f <= 0 || segs.to_i < 1 || segs.to_i > 64
        UI.messagebox('The radius must be positive and the segments between 1 and 64.')
        return false
      end
      self.radius = r.to_f
      self.segments = segs.to_i
      true
    end

    # Whether the new rounded surfaces get soft + smooth edges.
    def self.smooth?
      Sketchup.read_default(SECTION, 'smooth', true) ? true : false
    end

    def self.smooth=(on)
      Sketchup.write_default(SECTION, 'smooth', on ? true : false)
    end

    def self.engine_opts(mode, radius)
      { :mode => mode, :offset => radius, :segments => segments, :smooth => smooth? }
    end
  end

  # Parent (Model or ComponentDefinition) of the entities being edited.
  def self.context_parent(model)
    path = model.active_path
    path && !path.empty? ? path.last.definition : model
  end

  # Transformation from the coordinates the API reports for the open
  # context to model space, for drawing. Inside an open group or component
  # SketchUp already reports (and expects) world coordinates, in every
  # version, so this is the identity. (1.1.0-1.1.11 applied
  # Model#edit_transform on SketchUp 2020+, which drew everything shifted by
  # the group's placement when editing inside a group.)
  def self.edit_transform(_model)
    Geom::Transformation.new
  end

  # Average scale factor of a transformation (to convert a radius measured
  # in the model into the units of a scaled group).
  def self.scale_of(tr)
    a = tr.to_a
    sx = Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2)
    sy = Math.sqrt(a[4]**2 + a[5]**2 + a[6]**2)
    sz = Math.sqrt(a[8]**2 + a[9]**2 + a[10]**2)
    s = (sx + sy + sz) / 3.0
    s > 0 ? s : 1.0
  end

  # What the tools act on: edges of the open context (selected edges and
  # edges of selected faces) and whole groups/components.
  Target = Struct.new(:entities, :edges, :transform, :instance)

  def self.targets(model)
    ctx = context_parent(model)
    ctx_tr = edit_transform(model)
    edges = {}
    insts = []
    model.selection.to_a.each do |e|
      if e.is_a?(Sketchup::Edge) && e.parent == ctx
        edges[e] = true
      elsif e.is_a?(Sketchup::Face) && e.parent == ctx
        e.edges.each { |x| edges[x] = true }
      elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        insts << e
      end
    end
    list = []
    list << Target.new(model.active_entities, edges.keys, ctx_tr, nil) unless edges.empty?
    seen = {}
    insts.each do |inst|
      d = inst.definition
      next if seen[d]
      seen[d] = true
      list << Target.new(d.entities, d.entities.grep(Sketchup::Edge), ctx_tr * inst.transformation, inst)
    end
    list
  end

  # Rough number of faces the engine creates (usually within a factor of
  # 2): a corner where k selected edges meet gets a patch of about
  # 0.4 * (k - 1) * segments^2 faces, each edge a strip of segments faces.
  # Only used to keep long runs under control.
  def self.estimate_faces(list, segments)
    list.inject(0) do |acc, t|
      deg = Hash.new(0)
      t.edges.each do |e|
        deg[e.start] += 1
        deg[e.end] += 1
      end
      patches = deg.values.inject(0.0) { |sum, k| k >= 2 ? sum + 0.4 * (k - 1) * segments * segments : sum }
      acc + (patches + t.edges.size * segments).round
    end
  end

  def self.mode_segments(mode)
    mode == :bevel ? 1 : Settings.segments
  end

  # Drawing data of what is selected (changes only with the selection):
  #   :sel - selected edges as point pairs, :ends - their end points,
  #   :tris - selected faces as triangles, :boxes - group box edges,
  #   :edges - number of selected edges.
  def self.selection_data(model)
    res = { :sel => [], :ends => [], :tris => [], :boxes => [], :edges => 0 }
    selection_overlay(model, res)
    targets(model).each do |t|
      res[:edges] += t.edges.size
      next if res[:sel].size > 20_000
      t.edges.each do |e|
        a = e.start.position.transform(t.transform)
        b = e.end.position.transform(t.transform)
        res[:sel] << a << b
        res[:ends] << a << b if res[:ends].size < 4000
      end
    end
    res
  end

  # The result for a radius, without changing the model. Only the outline
  # is computed (where the new surfaces will meet the original faces), not
  # the surfaces themselves: much faster.
  #   :hard - outline segments (point pairs, model space), :soft - unused
  #   :error - message if it cannot be built, :reduced - edges reduced,
  #   :skipped - selection too large to preview,
  #   :warm - per target {edge key => offset / radius}, to pass back as
  #   warm when previewing a larger radius (faster fitting).
  def self.preview_result(model, mode, radius, warm = nil)
    res = { :hard => [], :soft => [], :error => nil, :reduced => 0, :skipped => false, :warm => [] }
    list = targets(model)
    total = list.inject(0) { |acc, t| acc + t.edges.size }
    return res if total == 0 || radius.nil? || radius <= 0
    if total > PREVIEW_MAX_EDGES
      res[:skipped] = true
      return res
    end
    list.each_with_index do |t, ti|
      base = radius / scale_of(t.transform)
      start = nil
      if warm && warm[ti]
        start = {}
        warm[ti].each { |v, f| start[v] = f * base }
      end
      opts = Settings.engine_opts(mode, base).merge(:refine => false, :max_steps => PREVIEW_FIT_STEPS,
                                                    :start_offsets => start, :outline_only => true)
      begin
        eng = Bridge.compute(t.edges, opts)[0]
      rescue Core::Error => err
        res[:error] = err.message
        res[:warm] << nil
        next
      rescue StandardError => err
        # A bug must not break the tool: report it once, show no preview.
        log_error('Preview', err)
        res[:error] = 'preview not available (details in Window > Ruby Console)'
        res[:warm] << nil
        next
      end
      res[:reduced] += eng.reduced.size
      w = {}
      eng.reduced.each { |v, d| w[v] = d / base }
      res[:warm] << w
      pts = eng.points
      tr = t.transform
      pt = lambda { |i| Geom::Point3d.new(pts[i][0], pts[i][1], pts[i][2]).transform(tr) }
      eng.outline_segments.each { |a, b| res[:hard] << pt.call(a) << pt.call(b) }
    end
    res
  end

  # Selection data and result together (used by tests and simple callers).
  def self.preview(model, mode, radius)
    selection_data(model).merge(preview_result(model, mode, radius))
  end

  # Drawing data for selected faces (triangles) and groups (box edges).
  def self.selection_overlay(model, res)
    ctx = context_parent(model)
    tr = edit_transform(model)
    model.selection.to_a.each do |e|
      if e.is_a?(Sketchup::Face) && e.parent == ctx && res[:tris].size < 30_000
        m = e.mesh(0)
        (1..m.count_polygons).each do |i|
          pts = m.polygon_points_at(i)
          (1...pts.size - 1).each { |k| res[:tris] << pts[0].transform(tr) << pts[k].transform(tr) << pts[k + 1].transform(tr) }
        end
      elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        res[:boxes].concat(box_lines(e.bounds, tr))
      end
    end
  end

  def self.box_lines(b, tr)
    c = (0..7).map { |i| b.corner(i).transform(tr) }
    [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]].flat_map do |i, j|
      [c[i], c[j]]
    end
  end

  # Applies a mode with a radius (model units) to the selection. Returns
  # true when the model was changed. quiet: no message box on a radius
  # that does not fit (the tool shows it in the status bar instead).
  def self.apply(mode, radius, quiet = false)
    model = Sketchup.active_model
    list = targets(model)
    if list.empty?
      UI.messagebox("#{MODE_NAMES[mode]}: select edges, faces, groups or components first.") unless quiet
      return false
    end
    est = estimate_faces(list, mode_segments(mode))
    if est > CONFIRM_FACES
      ans = UI.messagebox("#{MODE_NAMES[mode]}: this creates about #{est} faces and can take several " \
                          "minutes, during which SketchUp does not respond.\n\nContinue?", MB_YESNO)
      return false unless ans == IDYES
    end
    warnings = []
    op_id = format('%d-%06d', Time.now.to_i, rand(1_000_000))
    model.start_operation(MODE_NAMES[mode], true)
    begin
      list.each do |t|
        opts = Settings.engine_opts(mode, radius / scale_of(t.transform)).merge(:op_id => op_id)
        if t.instance
          warnings.concat(Bridge.process_instance(t.instance, opts))
        else
          warnings.concat(Bridge.process(t.entities, t.edges, opts))
        end
      end
      model.commit_operation
    rescue Core::Error, Bridge::Error => err
      model.abort_operation
      UI.messagebox("#{MODE_NAMES[mode]}: #{err.message}") unless quiet
      Sketchup.set_status_text("#{MODE_NAMES[mode]}: #{err.message}", SB_PROMPT)
      return false
    rescue StandardError => err
      model.abort_operation
      log_error(MODE_NAMES[mode], err, true)
      UI.messagebox("#{MODE_NAMES[mode]} failed: #{err.message}\n(details in Window > Ruby Console)")
      return false
    end
    Settings.radius = radius
    sel = model.selection
    sel.remove(sel.to_a.select { |e| !e.valid? || e.is_a?(Sketchup::Edge) || e.is_a?(Sketchup::Face) })
    notify("#{MODE_NAMES[mode]}: #{warnings.uniq.join(' ')}") unless warnings.empty?
    true
  end

  # Writes an unexpected error to the Ruby Console (once per message unless
  # always is set), so it can be reported.
  def self.log_error(what, err, always = false)
    @logged ||= {}
    key = "#{what}: #{err.class}: #{err.message}"
    return if @logged[key] && !always
    @logged[key] = true
    puts "Simple Corners #{VERSION} - #{what} failed: #{err.class}: #{err.message}"
    puts((err.backtrace || []).first(15).join("\n"))
  end

  # Non-blocking message (notification balloon where available).
  def self.notify(msg)
    puts msg
    if defined?(UI::Notification) && defined?(EXTENSION) && EXTENSION
      UI::Notification.new(EXTENSION, msg).show
    else
      Sketchup.set_status_text(msg, SB_PROMPT)
    end
  rescue StandardError
    Sketchup.set_status_text(msg, SB_PROMPT)
  end

  # Smooth / unsmooth the selection: edges shared by two selected faces
  # (or all edges of the selected faces if they share none, or the
  # selected edges). Smooths if any of them is hard, else unsmooths.
  def self.toggle_smooth_selection
    model = Sketchup.active_model
    sel = model.selection.to_a
    edges = sel.grep(Sketchup::Edge)
    if edges.empty?
      faces = sel.grep(Sketchup::Face)
      fset = {}
      faces.each { |f| fset[f] = true }
      all = faces.flat_map(&:edges).uniq
      inner = all.select { |e| e.faces.size == 2 && e.faces.all? { |f| fset[f] } }
      edges = inner.empty? ? all : inner
    end
    if edges.empty?
      UI.messagebox('Smooth / unsmooth: select faces (e.g. click a rounded surface) or edges first.')
      return false
    end
    on = edges.any? { |e| !e.soft? || !e.smooth? }
    model.start_operation(on ? 'Smooth Edges' : 'Unsmooth Edges', true)
    begin
      edges.each do |e|
        e.soft = on
        e.smooth = on
      end
      model.commit_operation
    rescue StandardError => err
      model.abort_operation
      log_error('Smooth / unsmooth', err, true)
      UI.messagebox("Smooth / unsmooth failed: #{err.message}\n(details in Window > Ruby Console)")
      return false
    end
    Sketchup.set_status_text("#{on ? 'Smoothed' : 'Unsmoothed'} #{edges.size} edge(s).", SB_PROMPT)
    true
  end

  # Icon file: vector on SketchUp 2016+ (SVG on Windows, PDF on macOS),
  # else the PNG of the given size (base name e.g. 'round' or 'cursor_round';
  # size nil = PNG without size suffix).
  def self.icon(name, size = nil)
    if Sketchup.version.to_i >= 16
      vec = File.join(PATH, 'icons', "#{name}.#{RUBY_PLATFORM =~ /darwin/ ? 'pdf' : 'svg'}")
      return vec if File.exist?(vec)
    end
    File.join(PATH, 'icons', size ? "#{name}_#{size}.png" : "#{name}.png")
  end

  def self.activate_tool(mode)
    Sketchup.active_model.select_tool(CornerTool.new(mode))
  end

  unless file_loaded?(__FILE__)
    cmds = {}
    MODES.each do |mode|
      cmd = UI::Command.new(MODE_NAMES[mode]) { activate_tool(mode) }
      cmd.small_icon = icon(mode, 16)
      cmd.large_icon = icon(mode, 24)
      cmd.tooltip = MODE_NAMES[mode]
      cmd.status_bar_text = MODE_TIPS[mode]
      cmds[mode] = cmd
    end

    smooth_cmd = UI::Command.new('Smooth new surfaces') { Settings.smooth = !Settings.smooth? }
    smooth_cmd.small_icon = icon(:smooth_new, 16)
    smooth_cmd.large_icon = icon(:smooth_new, 24)
    smooth_cmd.tooltip = 'Smooth new surfaces (on/off)'
    smooth_cmd.status_bar_text = 'On: new rounded surfaces get soft, smooth edges. Off: their segment lines stay visible.'
    smooth_cmd.set_validation_proc { Settings.smooth? ? MF_CHECKED : MF_UNCHECKED }

    toggle_cmd = UI::Command.new('Smooth / unsmooth selection') { toggle_smooth_selection }
    toggle_cmd.small_icon = icon(:smooth_sel, 16)
    toggle_cmd.large_icon = icon(:smooth_sel, 24)
    toggle_cmd.tooltip = 'Smooth / unsmooth selection'
    toggle_cmd.status_bar_text = 'Toggle soft/smooth on the edges between the selected faces (click a rounded surface to select it).'

    unround_cmd = UI::Command.new('Revert to sharp edge') { Unround.run }
    unround_cmd.small_icon = icon(:unround, 16)
    unround_cmd.large_icon = icon(:unround, 24)
    unround_cmd.tooltip = 'Revert to sharp edge (experimental, simple cases only)'
    unround_cmd.status_bar_text = 'Experimental, not perfect: rebuilds the sharp edge of one simple rounded or ' \
                                  'bevelled edge (select its surface first). Does not work on complex cases ' \
                                  '(several connected fillets, rounded corners, edited geometry). Check the ' \
                                  'result; Ctrl+Z undoes it.'

    menu = UI.menu('Plugins').add_submenu('Simple Corners')
    MODES.each { |m| menu.add_item(cmds[m]) }
    menu.add_separator
    menu.add_item(smooth_cmd)
    menu.add_item(toggle_cmd)
    menu.add_item(unround_cmd)
    menu.add_item('Radius and segments...') { Settings.dialog }

    tb = UI::Toolbar.new('Simple Corners')
    MODES.each { |m| tb.add_item(cmds[m]) }
    tb.add_separator
    tb.add_item(smooth_cmd)
    tb.add_item(toggle_cmd)
    tb.add_item(unround_cmd)
    state = tb.get_last_state
    if state == TB_VISIBLE
      tb.restore
    elsif state != TB_HIDDEN
      tb.show # never shown before
    end

    # Right-click on a selection: apply directly with the last radius.
    UI.add_context_menu_handler do |cmenu|
      sel = Sketchup.active_model.selection
      ok = sel.to_a.any? do |e|
        e.is_a?(Sketchup::Edge) || e.is_a?(Sketchup::Face) ||
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      end
      if ok
        sub = cmenu.add_submenu('Simple Corners')
        r = Settings.radius.to_l.to_s
        MODES.each { |m| sub.add_item("#{MODE_NAMES[m]} (#{r})") { apply(m, Settings.radius) } }
        sub.add_separator
        MODES.each { |m| sub.add_item("#{MODE_NAMES[m]} tool...") { activate_tool(m) } }
        sub.add_separator
        sub.add_item('Smooth / unsmooth selection') { toggle_smooth_selection }
        sub.add_item('Revert to sharp edge') { Unround.run }
      end
    end

    file_loaded(__FILE__)
  end
end
