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

  def self.register_extension(ext, _load)
    require ext.loader + '.rb'
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

    def initialize(vs, parent)
      @vs = vs
      @parent = parent
      @normal = newell
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
      @vs
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
      o = Object.new
      o.define_singleton_method(:count_polygons) { 1 }
      o.define_singleton_method(:polygon_points_at) { |_i| pts }
      o
    end

    def loops
      [outer_loop]
    end

    def edges
      (0...@vs.size).map { |i| @vs[i].common_edge(@vs[(i + 1) % @vs.size]) }
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
      f.edges.each { |e| e.faces << f }
      @items << f
      f
    end

    def erase_entities(list)
      list = [list] unless list.is_a?(Array)
      list.each do |e|
        next unless e.valid?
        if e.is_a?(Face)
          e.edges.each { |x| x.faces.delete(e) if x }
          e.mark_deleted
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
      @entities
    end

    def active_path
      nil
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
      Geom::Transformation.new
    end

    def bounds
      Geom::BoundingBox.new
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
