/* valaccodebasemodule.vala
 *
 * Copyright (C) 2006-2010  Jürg Billeter
 * Copyright (C) 2006-2008  Raffaele Sandrini
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Jürg Billeter <j@bitron.ch>
 * 	Raffaele Sandrini <raffaele@sandrini.ch>
 */

using Vala;

/**
 * Code visitor generating C Code.
 */
public class Maja.JSCodeGenerator : CodeGenerator {
	public class EmitContext {
		public Symbol? current_symbol;
		public Gee.LinkedList<Symbol> symbol_stack = new Gee.LinkedList<Symbol> ();
		public TryStatement current_try;
		public JSBlockBuilder js;
		public Gee.LinkedList<JSBlockBuilder> js_stack = new Gee.LinkedList<JSBlockBuilder> ();
		public int next_temp_var_id;
		public Gee.Map<string,string> variable_name_map = new Gee.HashMap<string,string> (str_hash, str_equal);

		public EmitContext (Symbol? symbol = null) {
			current_symbol = symbol;
		}

		public void push_symbol (Symbol symbol) {
			symbol_stack.offer_head (current_symbol);
			current_symbol = symbol;
		}

		public void pop_symbol () {
			current_symbol = symbol_stack.poll_head ();
		}
	}

	public CodeContext context { get; set; }

	public Symbol root_symbol;

	public JSFile jsfile;
	public JSBlockBuilder jsdecl;

	public EmitContext emit_context = new EmitContext ();
	public EmitContext init_emit_context = new EmitContext ();

	Gee.List<EmitContext> emit_context_stack = new Gee.ArrayList<EmitContext> ();

	public Symbol current_symbol { get { return emit_context.current_symbol; } }

	public TryStatement current_try {
		get { return emit_context.current_try; }
		set { emit_context.current_try = value; }
	}

	public TypeSymbol? current_type_symbol {
		get {
			var sym = current_symbol;
			while (sym != null) {
				if (sym is TypeSymbol) {
					return (TypeSymbol) sym;
				}
				sym = sym.parent_symbol;
			}
			return null;
		}
	}

	public Class? current_class {
		get { return current_type_symbol as Class; }
	}

	public Method? current_method {
		get {
			var sym = current_symbol;
			while (sym is Block) {
				sym = sym.parent_symbol;
			}
			return sym as Method;
		}
	}

	public PropertyAccessor? current_property_accessor {
		get {
			var sym = current_symbol;
			while (sym is Block) {
				sym = sym.parent_symbol;
			}
			return sym as PropertyAccessor;
		}
	}

	public DataType? current_return_type {
		get {
			var m = current_method;
			if (m != null) {
				return m.return_type;
			}

			var acc = current_property_accessor;
			if (acc != null) {
				if (acc.readable) {
					return acc.value_type;
				} else {
					return void_type;
				}
			}

			if (is_in_constructor () || is_in_destructor ()) {
				return void_type;
			}

			return null;
		}
	}

	bool is_in_constructor () {
		var sym = current_symbol;
		while (sym != null) {
			if (sym is Constructor) {
				return true;
			}
			sym = sym.parent_symbol;
		}
		return false;
	}

	bool is_in_destructor () {
		var sym = current_symbol;
		while (sym != null) {
			if (sym is Destructor) {
				return true;
			}
			sym = sym.parent_symbol;
		}
		return false;
	}

	public Block? current_closure_block {
		get {
			return next_closure_block (current_symbol);
		}
	}

	public unowned Block? next_closure_block (Symbol sym) {
		unowned Block block = null;
		while (true) {
			block = sym as Block;
			if (!(sym is Block || sym is Method)) {
				// no closure block
				break;
			}
			if (block != null && block.captured) {
				// closure block found
				break;
			}
			sym = sym.parent_symbol;
		}
		return block;
	}

	public EmitContext class_init_context;
	public EmitContext base_init_context;
	public EmitContext class_finalize_context;
	public EmitContext base_finalize_context;
	public EmitContext instance_init_context;
	public EmitContext instance_finalize_context;
	
	public JSBlockBuilder js { get { return emit_context.js; } }

	/* (constant) hash table with all reserved identifiers in the generated code */
	Set<string> reserved_identifiers;
	
	public int next_temp_var_id {
		get { return emit_context.next_temp_var_id; }
		set { emit_context.next_temp_var_id = value; }
	}

	public DataType void_type = new VoidType ();
	public DataType bool_type;
	public DataType char_type;
	public DataType int_type;
	public DataType uint_type;
	public DataType double_type;
	public DataType string_type;
	public DataType object_type;

	public JSCodeGenerator () {
		reserved_identifiers = new HashSet<string> (str_hash, str_equal);

        // TODO:
		reserved_identifiers.add ("this");
		reserved_identifiers.add ("for");
		reserved_identifiers.add ("while");

		// reserved for Maja naming conventions
		reserved_identifiers.add ("error");
		reserved_identifiers.add ("result");
	}

	public override void emit (CodeContext context) {
		this.context = context;

		root_symbol = context.root;

		bool_type = new BooleanType ((Struct) root_symbol.scope.lookup ("bool"));
		char_type = new IntegerType ((Struct) root_symbol.scope.lookup ("char"));
		string_type = new ObjectType ((Class) root_symbol.scope.lookup ("string"));

		/* we're only interested in non-pkg source files */
		var source_files = context.get_source_files ();
		foreach (SourceFile file in source_files) {
			if (file.file_type == SourceFileType.SOURCE ||
			    (context.header_filename != null && file.file_type == SourceFileType.FAST)) {
				file.accept (this);
			}
		}

	}

	public void push_context (EmitContext emit_context) {
		if (this.emit_context != null) {
			emit_context_stack.add (this.emit_context);
		}

		this.emit_context = emit_context;
	}

	public void pop_context () {
		if (emit_context_stack.size > 0) {
			this.emit_context = emit_context_stack[emit_context_stack.size - 1];
			emit_context_stack.remove_at (emit_context_stack.size - 1);
		} else {
			this.emit_context = null;
		}
	}

	public void push_function (JSBlockBuilder builder) {
		emit_context.js_stack.offer_head (builder);
		emit_context.js = builder;
	}

	public void pop_function () {
		emit_context.js = emit_context.js_stack.poll_head ();
	}

	public bool add_symbol_declaration (CCodeFile decl_space, Symbol sym, string name) {
		if (decl_space.add_declaration (name)) {
			return true;
		}
		if (sym.source_reference != null) {
			sym.source_reference.file.used = true;
		}
		if (sym.external_package) {
			// declaration complete
			return true;
		} else {
			// require declaration
			return false;
		}
	}

	public override void visit_source_file (SourceFile source_file) {
		jsfile = new JSFile ();
		jsdecl = new JSBlockBuilder (jsfile);

		source_file.accept_children (this);

		if (context.report.get_errors () > 0) {
			return;
		}

		/* For fast-vapi, we only wanted the header declarations
		 * to be emitted, so bail out here without writing the
		 * C code output.
		 */
		if (source_file.file_type == SourceFileType.FAST) {
			return;
		}

		var csource_filename = source_file.get_csource_filename ();
		var jssource_filename = "%s.js".printf (csource_filename.ndup (csource_filename.length - ".vala.c".length));
		if (!jsfile.store (jssource_filename, source_file.filename, context.version_header, context.debug)) {
			Report.error (null, "unable to open `%s' for writing".printf (jssource_filename));
		}

		jsfile = null;
	}

	public override void visit_class (Class cl) {
		push_context (new EmitContext (cl));

		// create real constructor
		var constructor = jsfunction ();
		constructor.stmt(jsexpr().member("this").member("_maja_init").call ());
		jsdecl.stmt (jsexpr().member(cl.name).assign(constructor));

		// init function
		init_emit_context = new EmitContext (cl);
		push_context (init_emit_context);
		var init_func = jsfunction ();
		push_function (init_func);
		pop_context ();

		jsdecl.stmt (jsexpr().member(cl.name).member("prototype").member("_maja_init").assign (init_func));

		cl.accept_children (this);
		pop_context ();
	}

	public override void visit_method (Method m) {
		push_context (new EmitContext (m));
		var func = jsfunction ();
		push_function (func);
		m.accept_children (this);
		pop_context ();

		// declare function
		var def = jsexpr ();
		if (current_type_symbol != null) {
			def.text (current_type_symbol.get_full_name ());
			if (m.binding == MemberBinding.INSTANCE) {
				def.member ("prototype");
			}
		}
		def.member (m.name).assign (func);
		jsdecl.stmt (def);
	}

	public override void visit_block (Block block) {
		emit_context.push_symbol (block);
		block.accept_children (this);
		emit_context.pop_symbol ();
	}

	public override void visit_declaration_statement (DeclarationStatement stmt) {
		stmt.declaration.accept (this);
	}

	public override void visit_local_variable (LocalVariable local) {
		JSCode rhs = null;
		if (local.initializer != null) {
			local.initializer.emit (this);
			rhs = get_jsvalue (local.initializer);
		} else {
			rhs = jsexpr().null_literal();
		}
		js.stmt (jsexpr().member(local.name).keyword("var").assign (rhs));
	}

	public override void visit_binary_expression (BinaryExpression expr) {
		var jsleft = get_jsvalue (expr.left);
		var jsright = get_jsvalue (expr.right);

		JSCode jscode = null;
		if (expr.operator == BinaryOperator.PLUS)
			jscode = jsexpr(jsleft).plus (jsright);
		set_jsvalue (expr, jscode);
	}

	public override void visit_integer_literal (IntegerLiteral expr) {
		set_jsvalue (expr, jsexpr().text (expr.value + expr.type_suffix));
	}

	public override void visit_return_statement (ReturnStatement stmt) {
		stmt.accept_children (this);
		js.stmt (jsexpr(get_jsvalue (stmt.return_expression)).keyword ("return"));
	}

	public override void visit_member_access (MemberAccess expr) {
		var local = expr.symbol_reference as LocalVariable;
		var jscode = jsexpr ();
		if (local != null) {
			jscode.text (local.name);
		}
		set_jsvalue (expr, jscode);
	}

	public override void visit_field (Field field) {
		if (field.binding == MemberBinding.INSTANCE) {
			push_context (init_emit_context);
			JSCode rhs = null;
			if (field.initializer != null) {
				field.initializer.emit (this);
				rhs = get_jsvalue (field.initializer);
			} else {
				rhs = jsexpr().null_literal();
			}
			js.stmt (jsexpr().member("this").member(field.name).assign (rhs));
			pop_context ();
		}
	}

	public JSCode? get_jsvalue (Expression expr) {
		if (expr.target_value == null) {
			return null;
		}
		var js_value = (JSValue) expr.target_value;
		return js_value.jscode;
	}

	public void set_jsvalue (Expression expr, JSCode code) {
		expr.target_value = new JSValue (expr.target_type, code);
	}

	public JSBlockBuilder jsfunction (JSList parameters = new JSList ()) {
		return new JSBlockBuilder (new JSBlock (null, "function", parameters));
	}

	public JSExpressionBuilder jsexpr (JSCode? initial = null) {
		return new JSExpressionBuilder (initial);
	}
}

public class Maja.JSValue : TargetValue {
	public JSCode jscode;

	public JSValue (DataType? value_type = null, JSCode? jscode = null) {
		base (value_type);
		this.jscode = jscode;
	}
}
