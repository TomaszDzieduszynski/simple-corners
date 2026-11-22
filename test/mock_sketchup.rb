$LOAD_PATH.unshift(File.join(__dir__, "stubs"))
# Minimal stand-in for the SketchUp Ruby API, enough to load the plugin
# and run the bridge/tool code outside SketchUp. Geometry semantics are
# simplified (no face splitting/merging, no holes).

GL_LINES = 1
GL_TRIANGLES = 4
SB_PROMPT = 0
SB_VCB_LABEL = 1
SB_VCB_VALUE = 2
MB_YESNO = 4
IDYES = 6
IDNO = 7
TB_HIDDEN = 0
TB_VISIBLE = 1
TB_NEVER_SHOWN = -1
MF_CHECKED = 8
MF_UNCHECKED = 0
COPY_MODIFIER_MASK = 4
CONSTRAIN_MODIFIER_MASK = 1
$mock_loaded = {}

def file_loaded?(f)
  $mock_loaded[f]
end

def file_loaded(f)
  $mock_loaded[f] = true
end

class Numeric
  def cm
    self / 2.54
  end

  def to_l
    to_f
  end
end

class String
  def to_l
    raise ArgumentError, 'bad length' unless self =~ /\A\s*-?\d+(\.\d+)?\s*(mm|cm|m|")?\s*\z/
    v = to_f
    case self
    when /mm/ then v / 25.4
    when /cm/ then v / 2.54
    when /m\s*\z/ then v / 0.0254
    else v
    end
  end
end

module Geom
  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def dot(o)
      @x * o.x + @y * o.y + @z * o.z
    end

    def length
      Math.sqrt(dot(self))
    end

    def to_a
      [@x, @y, @z]
    end

    def reverse
      Vector3d.new(-@x, -@y, -@z)
    end

    def length=(l)
      f = length > 0 ? l / length : 0.0
      @x *= f
      @y *= f
      @z *= f
    end
  end

  # Camera: enough for tools that read the eye and view direction.
  class Camera
    attr_reader :eye, :target

    def initialize(eye, target, persp = true)
      @eye = eye
      @target = target
      @persp = persp
    end

    def direction
      d = @eye.vector_to(@target)
      d.length = 1.0
      d
    end

    def perspective?
      @persp
    end
  end

  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def to_a
      [@x, @y, @z]
    end

    def -(o)
      Vector3d.new(@x - o.x, @y - o.y, @z - o.z)
    end

    def vector_to(o)
      Vector3d.new(o.x - @x, o.y - @y, o.z - @z)
    end

    def offset(v)
      Point3d.new(@x + v.x, @y + v.y, @z + v.z)
    end

    def distance(o)
      (self - o).length
    end

    # Column-major 4x4 matrix as in the SketchUp API (translation in 12-14).
    def transform(tr)
      a = tr.to_a
      Point3d.new(a[0] * @x + a[4] * @y + a[8] * @z + a[12],
                  a[1] * @x + a[5] * @y + a[9] * @z + a[13],
                  a[2] * @x + a[6] * @y + a[10] * @z + a[14])
    end
  end

  class Transformation
    def initialize(a = nil)
      @a = a || [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
    end

    def to_a
      @a.dup
    end

    def self.translation(v)
      v = v.to_a
      new([1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, v[0].to_f, v[1].to_f, v[2].to_f, 1.0])
    end

    def *(o)
      a = @a
      b = o.to_a
      Transformation.new((0...16).map { |i| r = i % 4; c = i / 4; (0...4).inject(0.0) { |acc, k| acc + a[k * 4 + r] * b[c * 4 + k] } })
    end
  end

  class BoundingBox
    def add(*_a)
      self
    end

    def corner(_i)
      Point3d.new(0, 0, 0)
    end
  end
end

module Sketchup
  @defaults = {}
  @next_id = 0

  def self.next_id
    @next_id += 1
  end

  class Color
    def initialize(*a)
      @a = a
    end
  end

  # Input point whose position comes from the view stub.
  class InputPoint
    attr_reader :position

    def pick(view, x, y, _ref = nil)
      @position = view.point_at(x, y)
      true
    end

    def copy!(o)
      @position = o.position
    end

    def valid?
      !@position.nil?
    end

    def display?
      false
    end

    def tooltip
      ''
    end

    def draw(_v); end
  end
  @status = []

  class << self
    attr_accessor :model, :status
  end

  def self.active_model
    @model
  end

  def self.read_default(sec, key, default = nil)
    @defaults.fetch([sec, key], default)
  end

  def self.write_default(sec, key, val)
    @defaults[[sec, key]] = val
  end

  def self.format_length(x)
    format('%.3f"', x)
  end

  def self.set_status_text(t, _pane = 0)
    @status << t
  end

  def self.version
    '17.0.18899'
  end

  # SketchUp's require: the path without its file extension (.rb/.rbe).
  def self.require(path)
    raise ArgumentError, "Sketchup.require takes the path without .rb: #{path}" if path =~ /\.rb[es]?\z/
    Kernel.require(path)
  end

  def self.register_extension(ext, _load)
    Kernel.require(ext.loader + '.rb')
    true
  end

  class Entity
    def entityID
      @entity_id ||= Sketchup.next_id
    end

    def valid?
      !@deleted
    end

    def mark_deleted
      @deleted = true
    end
  end

  class Drawingelement < Entity
    attr_accessor :material, :layer, :hidden

    def set_attribute(dict, key, val)
      ((@attrs ||= {})[dict] ||= {})[key] = val
    end

    def get_attribute(dict, key, default = nil)
      ((@attrs || {})[dict] || {}).fetch(key, default)
    end

    def hidden?
      @hidden ? true : false
    end

    # Dictionaries by name (pairs in @attrs, nested dictionaries in @dkids).
    def attribute_dictionaries
      return nil if (@attrs || {}).empty?
      @attrs.map { |n, pairs| AttributeDictionary.new(n, pairs, ((@dkids ||= {})[n] ||= {})) }
    end

    def attribute_dictionary(name, create = false)
      pairs = (@attrs ||= {})[name] || (create ? (@attrs[name] = {}) : nil)
      pairs && AttributeDictionary.new(name, pairs, ((@dkids ||= {})[name] ||= {}))
    end
  end

  class AttributeDictionary
    attr_reader :name

    def initialize(name, pairs, kids)
      @name = name
      @pairs = pairs
      @kids = kids
    end

    def each_pair(&blk)
      @pairs.each_pair(&blk)
    end

    def [](k)
      @pairs[k]
    end

    def []=(k, v)
      @pairs[k] = v
    end

    def attribute_dictionaries
      return nil if @kids.empty?
      @kids.map { |n, (pairs, kids)| AttributeDictionary.new(n, pairs, kids) }
    end

    def attribute_dictionary(name, create = false)
      e = @kids[name] || (create ? (@kids[name] = [{}, {}]) : nil)
      e && AttributeDictionary.new(name, e[0], e[1])
    end
  end

  class Vertex < Entity
    attr_reader :position, :edges

    def initialize(p)
      @position = p
      @edges = []
    end

    def faces
      @edges.flat_map(&:faces).uniq
    end

    def common_edge(o)
      @edges.find { |e| e.other(self) == o }
    end
  end

  class Edge < Drawingelement
    attr_reader :start, :end, :faces, :parent
    attr_accessor :soft, :smooth

    def initialize(a, b, parent)
      @start = a
      @end = b
      @faces = []
      @parent = parent
      a.edges << self
      b.edges << self
    end

    def vertices
      [@start, @end]
    end

    def length
      @start.position.distance(@end.position)
    end

    def other(v)
      v == @start ? @end : @start
    end
    alias other_vertex other

    def soft?
      @soft ? true : false
    end

    def smooth?
      @smooth ? true : false
    end

    def erase!
      @parent.entities.erase_entities([self])
    end
  end

  class ConstructionPoint < Drawingelement
    attr_reader :position

    def initialize(p, parent)
      @position = p
      @parent = parent
    end

    def erase!
      mark_deleted
    end
  end

  class Loop
    attr_reader :vertices

    def initialize(vs, outer)
      @vertices = vs
      @outer = outer
    end

    def outer?
      @outer
    end
  end

  class Face < Drawingelement
    attr_accessor :back_material
    attr_reader :parent, :normal

    # Face this one was created inside of (coplanar): erasing this face
    # leaves a hole in it, as in SketchUp.
    attr_accessor :inside
    attr_reader :holes

    def initialize(vs, parent)
      @vs = vs
      @parent = parent
      @normal = newell
      @holes = []
    end

    def add_hole(vs)
      return if @holes.any? { |h| h.size == vs.size && (h - vs).empty? }
      @holes << vs
      loop_edges(vs).each { |e| e.faces << self if e && !e.faces.include?(self) }
    end

    def loop_edges(vs)
      (0...vs.size).map { |i| vs[i].common_edge(vs[(i + 1) % vs.size]) }
    end

    # 2D coordinates in the face plane (dominant axis dropped).
    def flat(p)
      n = @normal.to_a.map(&:abs)
      keep = [0, 1, 2] - [n.index(n.max)]
      p.to_a.values_at(*keep)
    end

    def contains?(p)
      q = flat(p)
      inside = lambda do |vs|
        res = false
        vs.each_index do |i|
          a = flat(vs[i].position)
          b = flat(vs[(i + 1) % vs.size].position)
          next unless (a[1] > q[1]) != (b[1] > q[1])
          res = !res if q[0] < a[0] + (q[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
        end
        res
      end
      inside.call(@vs) && @holes.none? { |h| inside.call(h) }
    end

    def on_plane?(p)
      o = @vs[0].position
      d = [p.x - o.x, p.y - o.y, p.z - o.z]
      n = @normal.to_a
      (d[0] * n[0] + d[1] * n[1] + d[2] * n[2]).abs < 1e-6
    end

    # A point inside the face (centroid of an ear of the outer loop).
    def interior_point
      k = @vs.size
      k.times do |i|
        tri = [@vs[i - 1], @vs[i], @vs[(i + 1) % k]].map { |v| v.position.to_a }
        c = (0..2).map { |j| (tri[0][j] + tri[1][j] + tri[2][j]) / 3.0 }
        p = Geom::Point3d.new(*c)
        return p if contains?(p)
      end
      @vs[0].position
    end

    def newell
      n = [0.0, 0.0, 0.0]
      k = @vs.size
      k.times do |i|
        a = @vs[i].position
        b = @vs[(i + 1) % k].position
        n[0] += (a.y - b.y) * (a.z + b.z)
        n[1] += (a.z - b.z) * (a.x + b.x)
        n[2] += (a.x - b.x) * (a.y + b.y)
      end
      l = Math.sqrt(n[0]**2 + n[1]**2 + n[2]**2)
      Geom::Vector3d.new(n[0] / l, n[1] / l, n[2] / l)
    end

    def vertices
      @vs + @holes.flatten
    end

    def area
      n = [0.0, 0.0, 0.0]
      k = @vs.size
      k.times do |i|
        a = @vs[i].position
        b = @vs[(i + 1) % k].position
        n[0] += (a.y - b.y) * (a.z + b.z)
        n[1] += (a.z - b.z) * (a.x + b.x)
        n[2] += (a.x - b.x) * (a.y + b.y)
      end
      Math.sqrt(n[0]**2 + n[1]**2 + n[2]**2) / 2
    end

    def outer_loop
      Loop.new(@vs, true)
    end

    def mesh(_flags = 0)
      pts = @vs.map(&:position)
      ip = interior_point
      tri = [ip, ip, ip]
      holes = !@holes.empty?
      o = Object.new
      o.define_singleton_method(:count_polygons) { 1 }
      # A face with holes: one small triangle inside it (enough for tests
      # that only need a point of the face).
      o.define_singleton_method(:polygon_points_at) { |_i| holes ? tri : pts }
      o
    end

    def loops
      [outer_loop] + @holes.map { |h| Loop.new(h, false) }
    end

    def edges
      loop_edges(@vs) + @holes.flat_map { |h| loop_edges(h) }
    end

    def reverse!
      @vs = @vs.reverse
      @normal = @normal.reverse
      self
    end

    def all_connected
      seen = {}
      todo = [self]
      until todo.empty?
        e = todo.pop
        next if seen[e]
        seen[e] = true
        nxt = e.is_a?(Face) ? e.edges : e.faces + e.vertices.flat_map(&:edges)
        todo.concat(nxt.reject { |x| seen[x] })
      end
      seen.keys.reject { |x| x.is_a?(Vertex) }
    end

    def erase!
      @parent.entities.erase_entities([self])
    end
  end

  class Entities
    include Enumerable
    attr_reader :parent

    def initialize(parent)
      @parent = parent
      @items = []
      @verts = []
    end

    def each(&blk)
      @items.select(&:valid?).each(&blk)
    end

    def vertex_at(p)
      v = @verts.find { |x| x.valid? && x.position.distance(p) < 1e-9 }
      unless v
        v = Vertex.new(p)
        @verts << v
      end
      v
    end

    def add_face(pts)
      raise ArgumentError, 'not enough points' if pts.size < 3
      vs = pts.map { |p| vertex_at(p) }
      raise ArgumentError, 'duplicate points' if vs.uniq.size != vs.size
      vs.size.times do |i|
        a = vs[i]
        b = vs[(i + 1) % vs.size]
        next if a.common_edge(b)
        @items << Edge.new(a, b, @parent)
      end
      f = Face.new(vs, @parent)
      # Created inside a coplanar face: that face gets a hole there at once
      # (as in SketchUp), which stays when the new face is erased.
      ip = f.interior_point
      f.inside = @items.find do |h|
        h.is_a?(Face) && h.valid? && vs.all? { |v| h.on_plane?(v.position) } && h.contains?(ip)
      end
      # ...unless another face already lies inside the new one: SketchUp
      # then cuts no hole (seen in SketchUp 2017).
      if f.inside && @items.any? { |x| x.is_a?(Face) && x.valid? && x != f.inside && vs.all? { |v| x.on_plane?(v.position) } && f.contains?(x.interior_point) }
        f.inside = nil
      end
      f.edges.each { |e| e.faces << f }
      f.inside.add_hole(vs) if f.inside
      @items << f
      f
    end

    # Construction point (only kept and erased by the code under test).
    def add_cpoint(p)
      c = ConstructionPoint.new(p, @parent)
      @items << c
      c
    end

    def erase_entities(list)
      list = [list] unless list.is_a?(Array)
      list.each do |e|
        next unless e.valid?
        if e.is_a?(Face)
          e.edges.each { |x| x.faces.delete(e) if x }
          e.mark_deleted
          h = e.inside
          h.add_hole(e.vertices) if h && h.valid? && e.holes.empty?
        elsif e.is_a?(Edge)
          e.faces.dup.each { |f| erase_entities([f]) }
          e.vertices.each { |v| v.edges.delete(e) }
          e.mark_deleted
        end
      end
    end
  end

  class Selection
    include Enumerable

    def initialize
      @items = []
    end

    def each(&blk)
      @items.each(&blk)
    end

    def add(*a)
      a.flatten.each { |e| @items << e unless @items.include?(e) }
    end

    def remove(*a)
      a.flatten.each { |e| @items.delete(e) }
    end

    def include?(e)
      @items.include?(e)
    end

    def clear
      @items.clear
    end

    def empty?
      @items.empty?
    end

    def to_a
      @items.dup
    end
  end

  class Model
    attr_reader :entities, :selection, :ops

    def initialize
      @entities = Entities.new(self)
      @selection = Selection.new
      @ops = []
    end

    def active_entities
      @open_path && !@open_path.empty? ? @open_path.last.entities : @entities
    end

    def active_path
      @open_path && !@open_path.empty? ? @open_path : nil
    end

    # Test helper: groups open for editing, and the placement SketchUp
    # reports for them (Model#edit_transform). Positions stay local here.
    def open_for_test(path, edit_tr = nil)
      @open_path = path
      @edit_tr = edit_tr
    end

    def edit_transform
      @edit_tr || Geom::Transformation.new
    end

    def start_operation(name, _disable = false)
      @ops << [:start, name]
    end

    def commit_operation
      @ops << [:commit]
    end

    def abort_operation
      @ops << [:abort]
    end

    def active_view
      nil
    end

    attr_reader :tool_history

    def select_tool(t)
      (@tool_history ||= []) << t
      @tool = t
    end

    def bounds
      Geom::BoundingBox.new
    end
  end

  class ComponentDefinition
    attr_reader :entities, :instances

    def initialize
      @entities = Entities.new(self)
      @instances = []
    end
  end

  class Group < Drawingelement
    attr_reader :definition

    def initialize(definition = nil)
      @definition = definition || ComponentDefinition.new
      @definition.instances << self
    end

    def entities
      @definition.entities
    end

    def transformation
      @transformation || Geom::Transformation.new
    end

    # Test helper: placement in the parent (the geometry is not moved).
    attr_writer :transformation

    attr_writer :locked

    def locked?
      @locked ? true : false
    end

    # Test helper: explode fails (SketchUp returns false, the group stays).
    class << self
      attr_accessor :fail_explode
    end

    def bounds
      Geom::BoundingBox.new
    end

    # Entities collection the group was added to.
    attr_accessor :owner

    def erase!
      mark_deleted
    end

    # Moves the group's faces (with their holes) into its owner; returns
    # the new entities.
    def explode
      return false if Group.fail_explode
      out = []
      entities.grep(Face).each do |f|
        nf = @owner.add_face(f.outer_loop.vertices.map(&:position))
        nf.inside = nil
        nf.reverse! if nf.normal.dot(f.normal) < 0
        f.holes.each do |h|
          hf = @owner.add_face(h.map(&:position))
          hf.inside = nf
          hf.erase!
        end
        nf.material = f.material
        nf.back_material = f.back_material
        nf.layer = f.layer
        nf.instance_variable_set(:@attrs, f.instance_variable_get(:@attrs))
        nf.instance_variable_set(:@dkids, f.instance_variable_get(:@dkids))
        nf.hidden = f.hidden
        out << nf
        out.concat(nf.edges)
      end
      mark_deleted
      out
    end

    # Like SketchUp: a group sharing its definition with copies gets its
    # own copy of the geometry.
    def make_unique
      return self if @definition.instances.size <= 1
      old = @definition
      old.instances.delete(self)
      @definition = ComponentDefinition.new
      @definition.instances << self
      old.entities.grep(Face).each { |f| @definition.entities.add_face(f.vertices.map(&:position)) }
      # nested groups are copied as instances of the same definitions
      old.entities.grep(Group).each { |g| @definition.entities.add_group_copy(g) }
      self
    end
  end

  class ComponentInstance; end

  class Entities
    def add_group
      g = Group.new
      g.owner = self
      @items << g
      g
    end

    # Test helper (not SketchUp API): a copy of a group as Move + Ctrl
    # makes it, sharing the definition until one of them is edited.
    def add_group_copy(group)
      g = Group.new(group.definition)
      @items << g
      g
    end
  end
end

class SketchupExtension
  attr_accessor :description, :version, :creator, :copyright
  attr_reader :name, :loader

  def initialize(name, loader)
    @name = name
    @loader = loader
  end
end

module UI
  @messages = []

  class << self
    attr_reader :messages
  end

  # Answer to yes/no message boxes (tests may change it).
  @answer = IDYES

  class << self
    attr_accessor :answer
  end

  def self.messagebox(m, type = nil)
    @messages << m
    type == MB_YESNO ? @answer : 1
  end

  def self.beep; end

  def self.inputbox(_p, d, _t)
    d
  end

  class Menu
    def add_submenu(_n)
      Menu.new
    end

    def add_item(*_a)
      1
    end

    def add_separator; end

    def set_validation_proc(_id); end
  end

  def self.menu(_n)
    Menu.new
  end

  def self.add_context_menu_handler; end

  def self.create_cursor(*_a)
    1
  end

  def self.set_cursor(_id); end

  @timers = []
  class << self
    attr_reader :timers
  end

  def self.start_timer(_secs, _repeat = false, &blk)
    @timers << blk
    @timers.size
  end

  def self.stop_timer(_id); end

  class Command
    attr_accessor :small_icon, :large_icon, :tooltip, :status_bar_text

    def initialize(_n, &blk)
      @blk = blk
    end

    def set_validation_proc(&blk)
      @validation = blk
    end
  end

  class Toolbar
    def initialize(_n); end

    def add_item(_c); end

    def add_separator; end

    def get_last_state
      TB_NEVER_SHOWN
    end

    def show; end

    def restore; end
  end
end

# The camera class lives in Sketchup:: in the real API.
module Sketchup
  Camera = Geom::Camera
end
