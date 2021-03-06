require_relative "program"
require_relative 'ast'
require_relative 'type_inference/ast'
require_relative 'type_inference/ast_node'
require_relative 'type_inference/call'
require_relative 'type_inference/match'

module Crystal
  class Program
    def infer_type(node, options = {})
      if node
        if options[:stats]
          infer_type_with_stats node, options
        elsif options[:prof]
          infer_type_with_prof node
        else
          node.accept TypeVisitor.new(self)
          fix_empty_types node
          after_type_inference node
        end
      end
    end

    def infer_type_with_stats(node, options)
      options[:total_bm] += options[:bm].report('type inference:') { node.accept TypeVisitor.new(self) }
      options[:total_bm] += options[:bm].report('fix empty types') { fix_empty_types node }
      options[:total_bm] += options[:bm].report('afert type inference') { after_type_inference node }
    end

    def infer_type_with_prof(node)
      Profiler.profile_to('type_inference.html') { node.accept TypeVisitor.new(self) }
      Profiler.profile_to('fix_empty_types.html') { fix_empty_types node }
      Profiler.profile_to('after_type_inference.html') { after_type_inference node }
    end
  end

  class TypeVisitor < Visitor
    attr_accessor :mod
    attr_accessor :paths
    attr_accessor :call
    attr_accessor :owner
    attr_accessor :untyped_def
    attr_accessor :typed_def
    attr_accessor :arg_types
    attr_accessor :block
    @@regexps = {}
    @@counter = 0

    def initialize(mod, vars = {}, scope = nil, parent = nil, call = nil, owner = nil, untyped_def = nil, typed_def = nil, arg_types = nil, free_vars = nil, yield_vars = nil, type_filter_stack = [{}])
      @mod = mod
      @vars = vars
      @scope = scope
      @parent = parent
      @call = call
      @owner = owner
      @untyped_def = untyped_def
      @typed_def = typed_def
      @arg_types = arg_types
      @free_vars = free_vars
      @yield_vars = yield_vars
      @types = [mod]
      @while_stack = []
      @type_filter_stack = type_filter_stack
    end

    def visit_nil_literal(node)
      node.type = mod.nil
    end

    def visit_bool_literal(node)
      node.type = mod.bool
    end

    def visit_char_literal(node)
      node.type = mod.char
    end

    def visit_number_literal(node)
      case node.kind
      when :i8
        node.type = mod.int8
      when :i16
        node.type = mod.int16
      when :i32
        node.type = mod.int32
      when :i64
        node.type = mod.int64
      when :u8
        node.type = mod.uint8
      when :u16
        node.type = mod.uint16
      when :u32
        node.type = mod.uint32
      when :u64
        node.type = mod.uint64
      when :f32
        node.type = mod.float32
      when :f64
        node.type = mod.float64
      end
    end

    def visit_string_literal(node)
      node.type = mod.string
    end

    def visit_symbol_literal(node)
      node.type = mod.symbol
      mod.symbols << node.value
    end

    def visit_class_method(node)
      node.type = @scope.metaclass
    end

    def visit_def(node)
      if node.receiver
        # TODO: hack
        if node.receiver.is_a?(Var) && node.receiver.name == 'self'
          target_type = current_type.metaclass
        else
          target_type = lookup_ident_type(node.receiver).metaclass
        end
      else
        target_type = current_type
      end

      target_type.add_def node

      false
    end

    def visit_macro(node)
      if node.receiver
        # TODO: hack
        if node.receiver.is_a?(Var) && node.receiver.name == 'self'
          target_type = current_type.metaclass
        else
          target_type = lookup_ident_type(node.receiver).metaclass
        end
      else
        target_type = current_type
      end
      target_type.add_macro node
      false
    end

    def visit_class_def(node)
      superclass = if node.superclass
                 lookup_ident_type node.superclass
               else
                 mod.reference
               end

      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is not a class" unless type.is_a?(ClassType)
        if node.superclass && type.superclass != superclass
          node.raise "superclass mismatch for class #{type.name} (#{superclass.name} for #{type.superclass.name})"
        end
      else
        if node.type_vars
          type = GenericClassType.new current_type, node.name, superclass, node.type_vars
        else
          type = NonGenericClassType.new current_type, node.name, superclass
        end
        type.abstract = node.abstract
        current_type.types[node.name] = type
      end

      @types.push type

      true
    end

    def end_visit_class_def(node)
      @types.pop
    end

    def visit_module_def(node)
      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is not a module" unless type.module?
      else
        if node.type_vars
          type = GenericModuleType.new current_type, node.name, node.type_vars
        else
          type = NonGenericModuleType.new current_type, node.name
        end
        current_type.types[node.name] = type
      end

      @types.push type

      true
    end

    def end_visit_module_def(node)
      @types.pop
    end

    def visit_include(node)
      if node.name.is_a?(NewGenericClass)
        type = lookup_ident_type(node.name.name)
      else
        type = lookup_ident_type(node.name)
      end

      unless type.module?
        node.name.raise "#{node.name} is not a module"
      end

      if node.name.is_a?(NewGenericClass)
        unless type.generic?
          node.name.raise "#{type} is not a generic module"
        end

        if type.type_vars.length != node.name.type_vars.length
          node.name.raise "wrong number of type vars for #{type} (#{node.name.type_vars.length} for #{type.type_vars.length})"
        end

        type_vars_types = node.name.type_vars.map do |type_var|
          type_var_name = type_var.names[0]
          if current_type.generic? && current_type.type_vars.include?(type_var_name)
            type_var_name
          else
            lookup_ident_type(type_var)
          end
        end

        mapping = Hash[type.type_vars.zip(type_vars_types)]
        current_type.include IncludedGenericModule.new(type, current_type, mapping)
      else
        if type.generic?
          if current_type.generic?
            current_type_type_vars_length = current_type.type_vars.length
          else
            current_type_type_vars_length = 0
          end

          if current_type_type_vars_length != type.type_vars.length
            node.name.raise "#{type} is a generic module"
          end

          mapping = Hash[type.type_vars.zip(current_type.type_vars)]
          current_type.include IncludedGenericModule.new(type, current_type, mapping)
        else
          current_type.include type
        end
      end

      false
    end

    def visit_lib_def(node)
      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is not a lib" unless type.is_a?(LibType)
      else
        current_type.types[node.name] = type = LibType.new current_type, node.name, node.libname
      end
      @types.push type
    end

    def end_visit_lib_def(node)
      @types.pop
    end

    def end_visit_fun_def(node)
      args = node.args.map do |arg|
        check_primitive_like arg.type

        fun_arg = Arg.new(arg.name)
        fun_arg.location = arg.location
        fun_arg.type_restriction = fun_arg.type = maybe_ptr_type(arg.type.type.instance_type, arg.ptr)
        fun_arg
      end

      check_primitive_like node.return_type if node.return_type

      return_type = maybe_ptr_type(node.return_type ? node.return_type.type.instance_type : mod.nil, node.ptr)

      begin
        current_type.fun node.name, node.real_name, args, return_type, node.varargs, node
      rescue => ex
        node.raise ex.message
      end
    end

    def end_visit_type_def(node)
      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is already defined"
      else
        check_primitive_like node.type

        typed_def_type = maybe_ptr_type(node.type.type.instance_type, node.ptr)

        current_type.types[node.name] = TypeDefType.new current_type, node.name, typed_def_type
      end
    end

    def end_visit_struct_def(node)
      visit_struct_or_union_def node, CStructType
    end

    def end_visit_union_def(node)
      visit_struct_or_union_def node, CUnionType
    end

    def visit_struct_or_union_def(node, klass)
      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is already defined"
      else
        fields = node.fields.map do |field|
          check_primitive_like field.type

          Var.new(field.name, maybe_ptr_type(field.type.type.instance_type, field.ptr))
        end
        current_type.types[node.name] = klass.new(current_type, node.name, fields)
      end
    end

    def visit_enum_def(node)
      type = current_type.types[node.name]
      if type
        node.raise "#{node.name} is already defined"
      else
        counter = 0
        node.constants.each do |constant|
          if constant.default_value
            counter = constant.default_value.value.to_i
          else
            constant.default_value = NumberLiteral.new(counter, :i32)
          end
          counter += 1
        end
        current_type.types[node.name] = CEnumType.new(current_type, node.name, node.constants)
      end
    end

    def maybe_ptr_type(type, ptr)
      ptr.times do
        ptr_type = mod.pointer_of(type)
        type = ptr_type
      end
      type
    end

    def check_primitive_like(node)
      unless node.type.instance_type.primitive_like?
        msg = "only primitive types and structs are allowed in lib declarations"
        msg << " (did you mean Int32?)" if node.type.instance_type.equal?(@mod.types["Int"])
        msg << " (did you mean Float32?)" if node.type.instance_type.equal?(@mod.types["Float"])
        node.raise msg
      end
    end

    def visit_struct_set(node)
      node.bind_to @vars['value']
    end

    def visit_struct_get(node)
      struct_var = @scope.vars[node.name.to_s]
      node.bind_to struct_var
    end

    def visit_union_set(node)
      node.bind_to @vars['value']
    end

    def visit_union_get(node)
      union_var = @scope.vars[node.name.to_s]
      node.bind_to union_var
    end

    def visit_var(node)
      var = lookup_var node.name
      filter = build_var_filter var
      node.bind_to(filter || var)
      node.type_filters = and_type_filters({node.name => NotNilFilter}, var.type_filters)
    end

    def visit_declare_var(node)
      node.type = (lookup_ident_type node.declared_type).instance_type

      var = Var.new(node.name)
      var.bind_to node

      node.var = var

      @vars[node.name] = var

      false
    end

    def build_var_filter(var)
      filters = @type_filter_stack.map { |hash| hash[var.name] }.compact
      return if filters.empty?

      final_filter = filters.length == 1 ? filters[0] : AndTypeFilter.new(*filters)

      filtered_node = TypeFilteredNode.new(final_filter)
      filtered_node.bind_to var
      filtered_node
    end

    def and_type_filters(filters1, filters2)
      if filters1 && filters2
        new_filters = {}
        all_keys = (filters1.keys + filters2.keys).uniq
        all_keys.each do |name|
          filter1 = filters1[name]
          filter2 = filters2[name]
          if filter1 && filter2
            new_filters[name] = AndTypeFilter.new(filter1, filter2)
          elsif filter1
            new_filters[name] = filter1
          else
            new_filters[name] = filter2
          end
        end
        new_filters
      elsif filters1
        filters1
      else
        filters2
      end
    end

    def or_type_filters(filters1, filters2)
      # TODO: or type filters
      nil
    end

    def visit_global(node)
      var = mod.global_vars[node.name] or node.raise "uninitialized global #{node}"
      node.bind_to var
    end

    def visit_instance_var(node)
      var = lookup_instance_var node
      filter = build_var_filter var
      node.bind_to(filter || var)
      node.type_filters = {node.name => NotNilFilter}
    end

    def lookup_instance_var(node)
      if @scope.is_a?(Crystal::Program)
        node.raise "can't use instance variables at the top level"
      elsif @scope.is_a?(PrimitiveType)
        node.raise "can't use instance variables inside #{@scope.name}"
      end

      var = @scope.lookup_instance_var node.name
      if !@scope.has_instance_var_in_initialize?(node.name)
        var.bind_to mod.nil_var
      end

      var
    end

    def visit_assign(node)
      type_assign(node.target, node.value, node)
      false
    rescue Crystal::FrozenTypeException => ex
      node.raise "assinging to #{node.target}", ex
    end

    def visit_multi_assign(node)
      node.targets.each_with_index do |target, i|
        type_assign(target, node.values[i])
      end
      node.bind_to mod.nil_var
      false
    end

    def type_assign(target, value, node = nil)
      case target
      when Var
        value.accept self

        var = lookup_var target.name
        target.bind_to var

        if node
          node.bind_to value
          var.bind_to node
        else
          var.bind_to value
        end

        var.type_filters = node.type_filters = and_type_filters({target.name => NotNilFilter}, node.value.type_filters) if node
      when InstanceVar
        value.accept self

        var = lookup_instance_var target
        target.bind_to var

        if node
          node.bind_to value
          var.bind_to node
        else
          var.bind_to value
        end

        node.type_filters = and_type_filters({target.name => NotNilFilter}, node.value.type_filters) if node
      when Ident
        type = current_type.types[target.names.first]
        if type
          target.raise "already initialized constant #{target}"
        end

        target.bind_to value

        current_type.types[target.names.first] = Const.new(current_type, target.names.first, value, @types.clone, @scope)
      when Global
        value.accept self

        var = mod.global_vars[target.name] ||= Var.new(target.name)

        target.bind_to var

        if node
          node.bind_to value
          var.bind_to node
        end
      end
    end

    def visit_expressions(node)
      node.expressions.each_with_index do |exp, i|
        exp.accept self
        if exp.type && exp.type.is_a?(NoReturnType)
          node.expressions = node.expressions[0 .. i]
          break
        end
      end
      false
    end

    def end_visit_expressions(node)
      if node.last
        node.bind_to node.last
      else
        node.type = mod.nil
      end
    end

    def visit_while(node)
      node.cond.accept self

      @while_stack.push node
      @type_filter_stack.push node.cond.type_filters if node.cond.type_filters

      node.body.accept self if node.body

      @type_filter_stack.pop
      @while_stack.pop

      false
    end

    def end_visit_while(node)
      if !node.has_breaks && node.cond.is_a?(BoolLiteral) && node.cond.value == true
        node.type = mod.no_return
      else
        node.bind_to mod.nil_var
      end
    end

    def end_visit_break(node)
      container = @while_stack.last || (block && block.break)
      node.raise "Invalid break" unless container

      if container.is_a?(While)
        container.has_breaks = true
      end

      if node.exps.length > 0
        container.bind_to node.exps[0]
      else
        container.bind_to mod.nil_var
      end
    end

    def visit_if(node)
      node.cond.accept self

      if node.then
        @type_filter_stack.push node.cond.type_filters if node.cond.type_filters

        node.then.accept self

        @type_filter_stack.pop if node.cond.type_filters
      end

      if node.else
        node.else.accept self
      end

      case node.binary
      when :and
        node.type_filters = and_type_filters(node.then.type_filters, node.else.type_filters)
      when :or
        node.type_filters = or_type_filters(node.then.type_filters, node.else.type_filters)
      end

      # If the else branch exits, we can safely assume that the type
      # filters in the condition will still apply after the if
      if node.else && node.else.no_returns? && node.cond.type_filters
        @type_filter_stack[-1] = and_type_filters(@type_filter_stack.last, node.cond.type_filters)
      end

      false
    end

    def end_visit_if(node)
      nodes = []
      nodes << node.then if node.then
      nodes << node.else if node.else
      nodes << mod.nil_var unless node.then && node.else
      node.bind_to *nodes
    end

    def visit_ident(node)
      type = lookup_ident_type(node)
      if type.is_a?(Const)
        unless type.value.type
          old_types, old_scope, old_vars = @types, @scope, @vars
          @types, @scope, @vars = type.types, type.scope, {}
          type.value.accept self
          @types, @scope, @vars = old_types, old_scope, old_vars
        end
        node.target_const = type
        node.bind_to(type.value)
      else
        node.type = type.metaclass
      end
    end

    def lookup_ident_type(node)
      if @free_vars && !node.global && type = @free_vars[[node.names.first]]
        if node.names.length == 1
          target_type = type
        else
          target_type = type.lookup_type(node.names[1 .. -1])
        end
      elsif node.global
        target_type = mod.lookup_type node.names
      else
        target_type = (@scope || @types.last).lookup_type node.names
      end

      unless target_type
        node.raise("uninitialized constant #{node}")
      end

      target_type
    end

    def visit_allocate(node)
      if @scope.instance_type.is_a?(GenericClassType)
        node.raise "can't create instance of generic class #{@scope.instance_type} without specifying its type vars"
      end

      if @scope.instance_type.abstract
        node.raise "can't instantiate abstract class #{@scope.instance_type}"
      end

      @scope.instance_type.allocated = true
      node.type = @scope.instance_type
    end

    def end_visit_yield(node)
      block = @call.block or node.raise "no block given"

      if @yield_vars
        @yield_vars.each_with_index do |var, i|
          exp = node.exps[i]
          if exp
            if !exp.type.equal?(var.type)
              exp.raise "argument ##{i + 1} of yield expected to be #{var.type}, not #{exp.type}"
            end
            exp.freeze_type = true
          elsif !var.type.nil_type?
            node.raise "missing argument ##{i + 1} of yield with type #{var.type}"
          end
        end
      end

      block.args.each_with_index do |arg, i|
        exp = node.exps[i]
        if exp
          arg.bind_to exp
        else
          arg.bind_to mod.nil_var
        end
      end

      if block.body
        node.bind_to block.body
      else
        node.bind_to mod.nil_var
      end
    end

    def visit_block(node)
      if node.body
        block_vars = @vars.clone
        node.args.each do |arg|
          block_vars[arg.name] = arg
        end

        block_visitor = TypeVisitor.new(mod, block_vars, @scope, @parent, @call, @owner, @untyped_def, @typed_def, @arg_types, @free_vars, @yield_vars, @type_filter_stack)
        block_visitor.block = node
        node.body.accept block_visitor
      end
      false
    end

    def end_visit_simple_or(node)
      node.bind_to node.left
      node.bind_to node.right

      false
    end

    def visit_call(node)
      node.mod = mod
      node.scope = @scope || (@types.last ? @types.last.metaclass : nil)
      node.parent_visitor = self

      if expand_macro(node)
        return false
      end

      node.args.each_with_index do |arg, index|
        arg.add_observer node, :update_input
      end
      node.obj.add_observer node, :update_input if node.obj
      node.recalculate

      node.obj.accept self if node.obj
      node.args.each { |arg| arg.accept self }

      node.bubbling_exception do
        node.block.accept self if node.block
      end

      false
    end

    def end_visit_ident_union(node)
      node.type = mod.type_merge *node.idents.map { |ident| ident.type.instance_type }
    end

    def end_visit_new_generic_class(node)
      return if node.type

      instance_type = node.name.type.instance_type
      unless instance_type.type_vars
        node.raise "#{instance_type} is not a generic class"
      end

      if instance_type.type_vars.length != node.type_vars.length
        node.raise "wrong number of type vars for #{instance_type} (#{node.type_vars.length} for #{instance_type.type_vars.length})"
      end
      generic_type = instance_type.instantiate(node.type_vars.map { |var| var.type.instance_type })
      node.type = generic_type.metaclass
      false
    end

    def expand_macro(node)
      return false if node.obj || node.name == 'super'

      untyped_def = node.scope.lookup_macro(node.name, node.args.length) || mod.lookup_macro(node.name, node.args.length)
      return false unless untyped_def

      macros_cache_key = [untyped_def.object_id] + node.args.map { | arg| arg.class.object_id }
      unless expander = mod.macros_cache[macros_cache_key]
        expander = mod.macros_cache[macros_cache_key] = MacroExpander.new(mod, untyped_def)
      end

      generated_source = expander.expand node

      begin
        parser = Parser.new(generated_source, [Set.new(@vars.keys)])
        parser.filename = VirtualFile.new(untyped_def, generated_source)
        generated_nodes = parser.parse
      rescue Crystal::SyntaxException => ex
        node.raise "macro didn't expand to a valid program, it expanded to:\n\n#{'=' * 80}\n#{'-' * 80}\n#{number_lines generated_source}\n#{'-' * 80}\n#{ex.to_s(generated_source)}#{'=' * 80}"
      end

      generated_nodes = mod.normalize(generated_nodes)

      begin
        generated_nodes.accept self
      rescue Crystal::Exception => ex
        node.raise "macro didn't expand to a valid program, it expanded to:\n\n#{'=' * 80}\n#{'-' * 80}\n#{number_lines generated_source}\n#{'-' * 80}\n#{ex.to_s(generated_source)}#{'=' * 80}"
      end

      node.target_macro = generated_nodes
      node.type = generated_nodes.type

      true
    end

    def number_lines(source)
      source.lines.to_s_with_line_numbers
    end

    def visit_return(node)
      node.raise "can't return from top level" unless @typed_def

      if node.exps.empty?
        node.exps << NilLiteral.new
      end
      true
    end

    def end_visit_return(node)
      node.exps.each do |exp|
        @typed_def.bind_to exp
      end
    end

    def end_visit_is_a(node)
      node.type = mod.bool
      if node.obj.is_a?(Var)
        node.type_filters = {node.obj.name => SimpleTypeFilter.new(node.const.type.instance_type)}
      end
    end

    def end_visit_type_merge(node)
      node.bind_to *node.expressions
    end

    def visit_pointer_of(node)
      node.mod = mod
      var = if node.var.is_a?(Var)
              lookup_var node.var.name
            else
              lookup_instance_var node.var
            end
      node.bind_to var
      false
    end

    def visit_pointer_malloc(node)
      if @scope.instance_type.is_a?(GenericClassType)
        node.raise "can't malloc pointer without type, use Pointer(Type).malloc(size)"
      end

      node.type = @scope.instance_type
    end

    def visit_pointer_realloc(node)
      node.type = @scope
    end

    def visit_pointer_get_value(node)
      node.bind_to @scope.var
    end

    def visit_pointer_set_value(node)
      @scope.var.bind_to @vars['value']
      node.bind_to @vars['value']
    end

    def visit_pointer_add(node)
      node.type = @scope
    end

    def visit_pointer_cast(node)
      type = @vars['type'].type.instance_type
      if type.class?
        node.type = type
      else
        node.type = mod.pointer_of(type)
      end
    end

    def lookup_var(name)
      var = @vars[name]
      unless var
        var = Var.new name
        @vars[name] = var
      end
      var
    end

    def lookup_var_or_instance_var(var)
      if var.is_a?(Var)
        lookup_var(var.name)
      else
        @scope.lookup_instance_var(var.name)
      end
    end

    def current_type
      @types.last
    end

    def temp_name
      @@counter += 1
      "#temp_#{@@counter}"
    end

    def visit_and(node)
      raise "Bug: And node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_or(node)
      raise "Bug: Or node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_require(node)
      raise "Bug: Require node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_range_literal(node)
      raise "Bug: RangeLiteral node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_case(node)
      raise "Bug: Case node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_when(node)
      raise "Bug: When node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_regexp_literal(node)
      raise "Bug: RegexpLiteral node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_array_literal(node)
      raise "Bug: ArrayLiteral node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_hash_literal(node)
      raise "Bug: HashLiteral node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_unless(node)
      raise "Bug: Unless node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end

    def visit_string_interpolation(node)
      raise "Bug: StringInterpolation node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end
  end
end
