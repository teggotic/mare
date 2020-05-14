##
# The purpose of the Refer pass is to resolve identifiers, either as local
# variables or type declarations/aliases. The resolution of types is deferred
# to the earlier ReferType pass, on which this pass depends.
# Just like the earlier ReferType pass, the resolutions of the identifiers
# are kept as output state available to future passes wishing to retrieve
# information as to what a given identifier refers. Additionally, this pass
# tracks and validates some invariants related to references, and raises
# compilation errors if those forms are invalid.
#
# This pass does not mutate the Program topology.
# This pass does not mutate the AST.
# This pass may raise a compilation error.
# This pass keeps state at the per-type and per-function level.
# This pass produces output state at the per-type and per-function level.
#
class Mare::Compiler::Refer < Mare::AST::Visitor
  def initialize
    @map = {} of Program::Type::Link => ForType
  end

  def run(ctx, library)
    # For each type in the library, delve into type parameters and functions.
    library.types.each do |t|
      t_link = t.make_link(library)
      @map[t_link] = ForType.new(ctx, t.ident).tap(&.run)
    end
  end

  def [](t_link : Program::Type::Link) : ForType
    @map[t_link]
  end

  def []?(t_link : Program::Type::Link) : ForType
    @map[t_link]?
  end

  class ForType
    getter ctx : Context
    getter self_type : Type

    def initialize(@ctx, t_ident)
      @self_type = @ctx.refer_type[t_ident].as(Type)
      @map = {} of Program::Function::Link => ForFunc
      @infos = {} of AST::Node => Info
      @scopes = {} of AST::Group => Scope
    end

    def [](f_link : Program::Function::Link) : ForFunc
      @map[f_link]
    end

    def []?(f_link : Program::Function::Link) : ForFunc
      @map[f_link]?
    end

    def [](node : AST::Node) : Info
      @infos[node]
    end

    def []?(node : AST::Node) : Info?
      @infos[node]?
    end

    def []=(node : AST::Node, info : Info)
      @infos[node] = info
    end

    def scope?(group)
      @scopes[group]?
    end

    def set_scope(group, branch : ForBranch)
      @scopes[group] ||= Scope.new(branch.locals)
    end

    def self_type
      @self_type
    end

    def find_type?(node : AST::Identifier)
      @ctx.refer_type[node]?
    end

    def run
      self_type_defn = @self_type.defn(ctx)

      # For the type parameters in the type, run with a new ForBranch instance.
      self_type_defn.params.try(&.accept(ForBranch.new(self)))

      # For each function in the type, run with a new ForFunc instance.
      self_type_defn.functions.each do |f|
        ForFunc.new(self)
        .tap { |refer| @map[f.make_link(@self_type.link)] = refer }
        .tap(&.run(f))
      end
    end
  end

  class ForFunc
    property param_count = 0

    def initialize(@for_type : ForType)
      @infos = {} of AST::Node => Info
      @scopes = {} of AST::Group => Scope
    end

    def [](node)
      @infos[node]
    end

    def []?(node)
      @infos[node]?
    end

    def []=(node, info)
      @infos[node] = info
    end

    def scope?(group)
      @scopes[group]?
    end

    def set_scope(group, branch : ForBranch)
      @scopes[group] ||= Scope.new(branch.locals)
    end

    def find_type?(node)
      @for_type.find_type?(node)
    end

    def run(func)
      root = ForBranch.new(self)

      func.params.try(&.terms.each { |param|
        param.accept(root)
        root.create_param_local(param)
      })
      func.ret.try(&.accept(root))
      func.body.try(&.accept(root))
      func.yield_out.try(&.accept(root))
      func.yield_in.try(&.accept(root))

      func.body.try { |body| set_scope(body, root) }

      root
    end
  end

  class ForBranch < Mare::AST::Visitor
    getter locals
    getter consumes

    def initialize(
      @refer : (ForType | ForFunc),
      @locals = {} of String => (Local | LocalUnion),
      @consumes = {} of (Local | LocalUnion) => Source::Pos,
    )
    end

    def sub_branch(group : AST::Node?, init_locals = @locals.dup)
      ForBranch.new(@refer, init_locals, @consumes.dup).tap do |branch|
        @refer.set_scope(group, branch) if group.is_a?(AST::Group)
        group.try(&.accept(branch))
      end
    end

    # This visitor never replaces nodes, it just touches them and returns them.
    def visit(node)
      touch(node)
      node
    end

    # For an Identifier, resolve it to any known local or type if possible.
    def touch(node : AST::Identifier)
      name = node.value

      # If this is an @ symbol, it refers to the this/self object.
      info =
        if name == "@"
          Self::INSTANCE
        else
          # First, try to resolve as local, then as type, else it's unresolved.
          @locals[name]? || @refer.find_type?(node) || Unresolved::INSTANCE
        end

      # If this is an "error!" identifier, it's not actually unresolved.
      info = RaiseError::INSTANCE if info.is_a?(Unresolved) && name == "error!"

      # Raise an error if trying to use an "incomplete" union of locals.
      if info.is_a?(LocalUnion) && info.incomplete
        extra = info.list.map do |local|
          {local.as(Local).defn.pos, "it was assigned here"}
        end
        extra << {Source::Pos.none,
          "but there were other possible branches where it wasn't assigned"}

        Error.at node,
          "This variable can't be used here;" \
          " it was assigned a value in some but not all branches", extra
      end

      # Raise an error if trying to use a consumed local.
      if info.is_a?(Local | LocalUnion) && @consumes.has_key?(info)
        Error.at node,
          "This variable can't be used here; it might already be consumed", [
            {@consumes[info], "it was consumed here"}
          ]
      end
      if info.is_a?(LocalUnion) && info.list.any? { |l| @consumes.has_key?(l) }
        Error.at node,
          "This variable can't be used here; it might already be consumed",
          info.list.select { |l| @consumes.has_key?(l) }.map { |local|
            {@consumes[local], "it was consumed here"}
          }
      end

      @refer[node] = info
    end

    def touch(node : AST::Prefix)
      case node.op.value
      when "source_code_position_of_argument", "reflection_of_type",
           "identity_digest_of"
        nil # ignore this prefix type
      when "--"
        info = @refer[node.term]
        Error.at node, "Only a local variable can be consumed" \
          unless info.is_a?(Local | LocalUnion)

        @consumes[info] = node.pos
      else
        raise NotImplementedError.new(node.op.value)
      end
    end

    # For a FieldRead or FieldWrite, take note of it by name.
    def touch(node : AST::FieldRead | AST::FieldWrite)
      @refer[node] = Field.new(node.value)
    end

    # We conditionally visit the children of a `.` relation with this visitor;
    # See the logic in the touch method below.
    def visit_children?(node : AST::Relate)
      !(node.op.value == ".")
    end

    # For a Relate, pay attention to any relations that are relevant to us.
    def touch(node : AST::Relate)
      case node.op.value
      when "="
        info = @refer[node.lhs]?
        create_local(node.lhs) if info.nil? || info == Unresolved::INSTANCE
      when "."
        node.lhs.accept(self)
        ident, args, yield_params, yield_block = AST::Extract.call(node)
        ident.accept(self)
        args.try(&.accept(self))
        touch_yield_loop(yield_params, yield_block)
      end
    end

    # For a Group, pay attention to any styles that are relevant to us.
    def touch(node : AST::Group)
      # If we have a whitespace-delimited group where the first term has info,
      # apply that info to the whole group.
      # For example, this applies to type parameters with constraints.
      if node.style == " "
        info = @refer[node.terms.first]?
        @refer[node] = info if info
      end
    end

    # We don't visit anything under a choice with this visitor;
    # we instead spawn new visitor instances in the touch method below.
    def visit_children?(node : AST::Choice)
      false
    end

    # For a Choice, do a branching analysis of the clauses contained within it.
    def touch(node : AST::Choice)
      # Prepare to collect the list of new locals exposed in each branch.
      branch_locals = {} of String => Array(Local | LocalUnion)
      body_consumes = {} of (Local | LocalUnion) => Source::Pos

      # Iterate over each clause, visiting both the cond and body of the clause.
      node.list.each do |cond, body|
        # Visit the cond first.
        cond_branch = sub_branch(cond)

        # Absorb any consumes from the cond branch into this parent branch.
        # This makes them visible both in the parent and in future sub branches.
        @consumes.merge!(cond_branch.consumes)

        # Visit the body next. Locals from the cond are available in the body.
        # Consumes from any earlier cond are also visible in the body.
        body_branch = sub_branch(body, cond_branch.locals.dup)

        # Collect any consumes from the body branch.
        body_consumes.merge!(body_branch.consumes)

        # Collect the list of new locals exposed in the body branch.
        body_branch.locals.each do |name, local|
          next if @locals[name]?
          (branch_locals[name] ||= Array(Local | LocalUnion).new) << local
        end
      end

      # Absorb any consumes from the cond branches into this parent branch.
      @consumes.merge!(body_consumes)

      # Expose the locals from the branches as LocalUnion instances.
      # Those locals that were exposed in only some of the branches are to be
      # marked as incomplete, so that we'll see an error if we try to use them.
      branch_locals.each do |name, list|
        info = LocalUnion.build(list)
        info.incomplete = true if list.size < node.list.size
        @locals[name] = info
      end
    end

    # We don't visit anything under a choice with this visitor;
    # we instead spawn new visitor instances in the touch method below.
    def visit_children?(node : AST::Loop)
      false
    end

    # For a Loop, do a branching analysis of the clauses contained within it.
    def touch(node : AST::Loop)
      # Prepare to collect the list of new locals exposed in each branch.
      branch_locals = {} of String => Array(Local | LocalUnion)
      body_consumes = {} of (Local | LocalUnion) => Source::Pos

      # Visit the loop cond twice (nested) to simulate repeated execution.
      cond_branch = sub_branch(node.cond)
      cond_branch_2 = cond_branch.sub_branch(node.cond)

      # Absorb any consumes from the cond branch into this parent branch.
      # This makes them visible both in the parent and in future sub branches.
      @consumes.merge!(cond_branch.consumes)

      # Now, visit the else body, if any.
      node.else_body.try do |else_body|
        else_branch = sub_branch(else_body)

        # Collect any consumes from the else body branch.
        body_consumes.merge!(else_branch.consumes)
      end

      # Now, visit the main body twice (nested) to simulate repeated execution.
      body_branch = sub_branch(node.body)
      body_branch_2 = body_branch.sub_branch(node.body, @locals.dup)

      # Collect any consumes from the body branch.
      body_consumes.merge!(body_branch.consumes)

      # Absorb any consumes from the body branches into this parent branch.
      @consumes.merge!(body_consumes)

      # TODO: Is it possible/safe to collect locals from the body branches?
    end

    def touch_yield_loop(params : AST::Group?, block : AST::Group?)
      return unless params || block

      # Visit params and block twice (nested) to simulate repeated execution
      sub_branch = sub_branch(params)
      params.try(&.terms.each { |param| sub_branch.create_local(param) })
      block.try(&.accept(sub_branch))
      sub_branch2 = sub_branch.sub_branch(params, @locals.dup)
      params.try(&.terms.each { |param| sub_branch2.create_local(param) })
      block.try(&.accept(sub_branch2))
      @refer.set_scope(block, sub_branch) if block.is_a?(AST::Group)

      # Absorb any consumes from the block branch into this parent branch.
      @consumes.merge!(sub_branch.consumes)
    end

    def touch(node : AST::Node)
      # On all other nodes, do nothing.
    end

    def create_local(node : AST::Identifier)
      # This will be a new local, so if the identifier already matched an
      # existing local, it would shadow that, which we don't currently allow.
      info = @refer[node]
      if info.is_a?(Local)
        Error.at node, "This variable shadows an existing variable", [
          {info.defn, "the first definition was here"},
        ]
      end

      # Create the local entry, so later references to this name will see it.
      local = Local.new(node.value, node)
      @locals[node.value] = local unless node.value == "_"
      @refer[node] = local
    end

    def create_local(node : AST::Node)
      raise NotImplementedError.new(node.to_a) \
        unless node.is_a?(AST::Group) && node.style == " " && node.terms.size == 2

      create_local(node.terms[0])
      @refer[node] = @refer[node.terms[0]]
    end

    def create_param_local(node : AST::Identifier)
      # We don't support creating locals outside of a function.
      refer = @refer
      raise NotImplementedError.new(@refer.class) unless refer.is_a?(ForFunc)

      case refer[node]
      when Unresolved
        # Treat this as a parameter with only an identifier and no type.
        ident = node

        local = Local.new(ident.value, ident, refer.param_count += 1)
        @locals[ident.value] = local unless ident.value == "_"
        refer[ident] = local
      else
        # Treat this as a parameter with only a type and no identifier.
        # Do nothing other than increment the parameter count, because
        # we don't want to overwrite the Type info for this node.
        # We don't need to create a Local anyway, because there's no way to
        # fetch the value of this parameter later (because it has no identifier).
        refer.param_count += 1
      end
    end

    def create_param_local(node : AST::Relate)
      raise NotImplementedError.new(node.to_a) \
        unless node.op.value == "DEFAULTPARAM"

      create_param_local(node.lhs)

      @refer[node] = @refer[node.lhs]
    end

    def create_param_local(node : AST::Qualify)
      raise NotImplementedError.new(node.to_a) \
        unless node.term.is_a?(AST::Identifier) && node.group.style == "("

      create_param_local(node.term)

      @refer[node] = @refer[node.term]
    end

    def create_param_local(node : AST::Node)
      raise NotImplementedError.new(node.to_a) \
        unless node.is_a?(AST::Group) && node.style == " " && node.terms.size == 2

      # We don't support creating locals outside of a function.
      refer = @refer
      raise NotImplementedError.new(@refer.class) unless refer.is_a?(ForFunc)

      ident = node.terms[0].as(AST::Identifier)

      local = Local.new(ident.value, ident, refer.param_count += 1)
      @locals[ident.value] = local unless ident.value == "_"
      refer[ident] = local

      refer[node] = refer[ident]
    end
  end
end
