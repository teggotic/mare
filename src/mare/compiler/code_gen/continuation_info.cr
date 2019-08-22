class Mare::Compiler::CodeGen
  class ContinuationInfo
    private getter g : CodeGen
    private getter gtype : GenType
    private getter gfunc : GenFunc
    
    def initialize(@g, @gtype, @gfunc)
    end
    
    private def ctx; g.ctx end
    private def builder; g.builder end
    
    @struct_element_types : Array(LLVM::Type)?
    def struct_element_types
      (@struct_element_types ||= (
        list = [] of LLVM::Type
        list << gfunc.continuation_llvm_func_ptr
        list << g.llvm_type_of(gtype) if gfunc.needs_receiver?
        list.concat \
          ctx.inventory.locals[gfunc.func].map { |ref| g.llvm_mem_type_of(ref.defn, gfunc) }
        list
      )).not_nil!
    end
    
    def struct_gep_for_next_func(cont : LLVM::Value)
      next_func_gep = builder.struct_gep(cont, 0, "CONT.NEXT.GEP")
    end
    
    def struct_gep_for_receiver(cont : LLVM::Value)
      raise "no receiver for this gfunc" unless gfunc.needs_receiver?
      builder.struct_gep(cont, 1, "CONT.@.GEP")
    end
    
    def struct_gep_for_local(cont : LLVM::Value, ref : Refer::Local)
      index = 1
      index += 1 if gfunc.needs_receiver?
      index += ctx.inventory.locals[gfunc.func].index(ref).not_nil!
      
      builder.struct_gep(cont, index, "CONT.#{ref.name}.GEP")
    end
    
    def get_next_func(cont : LLVM::Value)
      next_func_gep = struct_gep_for_next_func(cont)
      builder.load(next_func_gep, "CONT.NEXT")
    end
    
    def set_next_func(cont : LLVM::Value, next_func : LLVM::Value?)
      next_func_gep = struct_gep_for_next_func(cont)
      
      # Assign the next continuation function to the function pointer.
      # If nil, then we assign a NULL pointer, signifying the final return value,
      # telling the caller not to continue the yield block iteration any more.
      if next_func
        next_func = builder.bit_cast(next_func, gfunc.continuation_llvm_func_ptr, "#{next_func.name}.GENERIC")
        builder.store(next_func, next_func_gep)
      else
        # Assign NULL to the continuation's function pointer, signifying the end.
        builder.store(gfunc.continuation_llvm_func_ptr.null, next_func_gep)
      end
    end
    
    def check_next_func_is_null(cont : LLVM::Value)
      null = gfunc.continuation_llvm_func_ptr.null
      builder.icmp(LLVM::IntPredicate::EQ, get_next_func(cont), null)
    end
    
    def initial_cont(frame : Frame)
      # TODO: Can we allocate with malloc instead so we can use explicit free?
      # TODO: Can we avoid allocation entirely by not passing as a pointer?
      # Doing so would reduce overhead of yielding calls, at the expense of
      # making the code generation for virtual calls a bit more complicated,
      # since we would still need a pointer for those cases (because each
      # implementation of a yielding call may have different state sizes).
      cont = g.gen_alloc(gfunc.continuation_type, "CONT")
      
      frame.continuation_value = cont
      
      # If the function has a receiver, store it in the continuation now.
      # For the rest of the life of the continuation value, we'll assume it
      # is there and that it has no need to change over that lifetime.
      if gfunc.needs_receiver?
        builder.store(frame.llvm_func.params[0], struct_gep_for_receiver(cont))
      end
    end
    
    def continue_cont(frame : Frame)
      # Grab the continuation value from the first and only parameter.
      raise "weird parameter signature" if frame.llvm_func.params.size > 1
      cont = frame.continuation_value = frame.llvm_func.params[0]
      # TODO: gather "yield in" parameter here as well
      
      # Get the receiver value from the continuation, if applicable.
      frame.receiver_value =
        if gfunc.needs_receiver?
          builder.load(struct_gep_for_receiver(cont), "@")
        elsif gtype && gtype.singleton?
          gtype.singleton
        end
      
      # We need to eagerly generate the local geps here in the entry block,
      # since if we generate them lazily, they may not dominate all uses
      # in the LLVM dominator tree analysis (which checks declare-before-use).
      ctx.inventory.locals[gfunc.func].each_with_index do |ref, ref_index|
        ref_index = ref_index + 1 # skip the first element - the next func
        ref_index = ref_index + 1 if gfunc.needs_receiver? # skip the receiver
        ref_type = struct_element_types[ref_index]
        frame.current_locals[ref] = g.gen_local_gep(ref, ref_type)
      end
    end
  end
end
