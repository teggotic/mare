class Mare::Refer < Mare::AST::Visitor
  alias RID = UInt64
  
  class Error < Exception
  end
  
  module Unresolved
    def self.pos
      SourcePos.none
    end
  end
  
  class Local
    getter pos : SourcePos
    getter name : String
    getter defn_rid : RID
    getter param_idx : Int32?
    
    def initialize(@pos, @name, @defn_rid, @param_idx = nil)
    end
  end
  
  class Const
    getter defn : Program::Type
    
    def initialize(@defn)
    end
    
    def pos
      @defn.ident.pos
    end
  end
  
  alias Info = (Unresolved.class | Local | Const)
  
  def initialize(consts : Hash(String, Const))
    @create_params = false
    @last_rid = 0_u64
    @last_param = 0
    @rids = {} of RID => Info
    @current_locals = {} of String => Local
    @current_consts = consts.dup.as(Hash(String, Const))
  end
  
  def [](node)
    @rids[node.rid]
  end
  
  def self.run(ctx)
    consts = {} of String => Const
    ctx.program.types.each_with_index do |t, index|
      name = t.ident.value
      consts[name] = Const.new(t)
    end
    
    ctx.program.types.each do |t|
      t.functions.each do |f|
        new(consts).run(f)
      end
    end
  end
  
  def run(func)
    func.refer = self
    
    # Read parameter declarations, creating locals within that list.
    with_create_params { func.params.try { |params| params.accept(self) } }
    
    # Now read the function body.
    func.body.try { |body| body.accept(self) }
  end
  
  # Yield with @create_params set to true, then after running the given block
  # set the @create_params field back to its original value.
  private def with_create_params(&block)
    orig = @create_params
    @create_params = true
    yield
    @create_params = orig
  end
  
  # This visitor never replaces nodes, it just touches them and returns them.
  def visit(node)
    touch(node)
    node
  end
  
  # For an Identifier, resolve it to any known local or constant if possible.
  def touch(node : AST::Identifier)
    name = node.value
    rid = (@last_rid += 1)
    
    # First, try to resolve as a local, then try consts, else it's unresolved.
    info = @current_locals[name]? || @current_consts[name]? || Unresolved
    
    node.rid = rid
    @rids[rid] = info
  end
  
  # For a Relate, pay attention to any relations that are relevant to us.
  def touch(node : AST::Relate)
    if node.op.value == " " && @create_params
      create_local(node.lhs.as(AST::Identifier), true)
      node.rid = node.lhs.rid
    elsif node.op.value == "="
      create_local(node.lhs, false)
    end
  end
  
  def touch(node : AST::Node)
    # On all other nodes, do nothing.
  end
  
  def create_local(node : AST::Identifier, is_param : Bool)
    # This will be a new local, so if the identifier already matched an
    # existing local, it would shadow that, which we don't currently allow.
    if @rids[node.rid].is_a?(Local)
      raise Error.new([
        "This local shadows an existing local:",
        node.pos.show,
        "- the first definition was here:",
        @rids[node.rid].pos.show,
      ].join("\n"))
    end
    
    # This local is a parameter, so set the new parameter index.
    param_idx = (@last_param += 1) if is_param
    
    # Create the local entry, so later references to this name will see it.
    local = Local.new(node.pos, node.value, node.rid, param_idx)
    @current_locals[node.value] = local
    @rids[node.rid] = local
  end
  
  def create_local(node : AST::Node, is_param : Bool)
    raise NotImplementedError.new(node.to_a) \
      unless node.is_a?(AST::Relate) && node.op.value == " "
    
    create_local(node.lhs, is_param)
    node.rid = node.lhs.rid
  end
end