#+feature dynamic-literals

package main

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "shared:odd/pipe"
import "tokenizer"

Pipe :: pipe.Pipe
sh :: pipe.run_command

Function_Type :: enum {
	Callback,
}

Function :: union {
	Compiled_Function,
	Lisp_Function,
}

Compiled_Function :: struct {
	fn:        Callback_Proc,
	parameter: [^]Args,
	nargs:     c.int,
	pos:       tokenizer.Pos,
}

Lisp_Function :: struct {
	fn:        Callback_Proc,
	parameter: [^]Args,
	nargs:     c.int,
	pos:       tokenizer.Pos,
	inst:      ^Code,
}

Arg_Specialization :: enum {
	Variadic = 1,
	Optional = 2,
}

Args :: struct {
	name:           cstring,
	type:           Element_Type,
	specialization: bit_set[Arg_Specialization],
}

Library :: struct {
	library: dynlib.Library,
	plugin:  Plugin,
}

Plugin :: struct {
	name:     cstring,
	callback: Callback_Proc,
	args:     [^]Args,
	nargs:    c.int,
	fn_type:  Function_Type, // currently unused, TODO: turn callback into union
}

Callback_Proc :: #type proc(nargs: c.int, args: [^]Element) -> ^Element
Lsh_Plugin_Proc :: #type proc() -> Plugin

global_function_table: map[string]Function

Digit_Variadic := Args{nil, .Digit, {.Variadic}}
Any_Variadic := Args{nil, .Any, {.Variadic}}

defun := Compiled_Function {
	fn = defun_proc,
	parameter = &Any_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}


odin_source_code_location_to_tokenizer_pos :: proc "contextless" (
	loc: runtime.Source_Code_Location,
) -> tokenizer.Pos {
	return tokenizer.Pos {
		file = loc.file_path,
		line = cast(int)loc.line,
		column = cast(int)loc.column,
	}
}

odin_pos :: odin_source_code_location_to_tokenizer_pos

defun_exec_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return nil
}

defun_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	if nargs < 2 do return nil

	name := args[0]
	assert(name.type == .Ident)

	list := args[1]
	assert(list.type == .List)

	inst := new(Code)
	inst.fn = defun_exec_proc
	inst.args = make([dynamic]^Element, nargs)

	fn: Lisp_Function
	fn.fn = defun_exec_proc
	fn.parameter, fn.nargs = gen_args(&list.list)

	_body := mem.slice_ptr(args, cast(int)nargs)
	body := _body[1:]

	code, ok := codegen(body, fn)

	global_function_table[string(name.text)] = fn

	return nil
}

gen_args :: proc(l: ^List) -> ([^]Args, c.int) {
	if l == nil do return nil, 0

	car := l.car

	if car == nil || car.type != .Ident do return nil, 0

	cdr := l.cdr

	if cdr == nil do return nil, 0

	args := make([dynamic]Args, 2)

	append_arg :: proc(a: ^[dynamic]Args, name: cstring, e: ^Element) {
		arg := new(Args)
		arg.name = name

		#partial switch e.type {
		case .Ident:
			switch e.text {
			case "string":
				arg.type = .String
			case "int":
				arg.type = .Integer
			case "float":
				arg.type = .Float
			}
		case:
			panic("tbd")
		}

		append(a, arg^)
	}

	append_arg(&args, car.text, &cdr[0])

	for i: int = 1; i < len(cdr); {
		name := cdr[i].text
		append_arg(&args, name, &cdr[i + 1])
		i += 2
		break
	}

	return raw_data(args), cast(c.int)len(args)
}

shell := Compiled_Function {
	fn = shell_proc,
	parameter = &Any_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

shell_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	argv: [dynamic]string
	for arg in mem.slice_ptr(args, cast(int)nargs) {
		#partial switch arg.type {
		case .String, .Quote, .Ident:
			append(&argv, string(arg.text))
		case .Float:
			append(&argv, fmt.tprintf("%f", arg.float))
		case .Integer:
			append(&argv, fmt.tprintf("%d", arg.float))
		}
	}
	sh(argv[:])
	return nil
}

vaargs_gen :: proc(var: []Element, fn: Function) -> (inst: ^Code, ok: bool) {
	switch f in fn {
	case Lisp_Function:
	case Compiled_Function:
		inst = new(Code)
		inst.fn = f.fn
		inst.args = make([dynamic]^Element, len(var))
		arg := f.parameter[0]
		for i in 0 ..< len(var) {
			bind_arg(inst, var, &arg, i) or_return
		}
	}
	return inst, true
}

get_symbol :: proc(var: ^Element) -> (Function, bool) {
	#partial switch var.type {
	case .Ident:
		return global_function_table[string(var.text)]
	case .Operator:
		return global_function_table[tokenizer.tokens[cast(tokenizer.Token_Kind)var.operator]]
	case:
		return Function{}, false
	}
}

codegen :: proc(var: []Element, fn: Function) -> (inst: ^Code, ok: bool) {
	switch f in fn {
	case Lisp_Function:
	case Compiled_Function:
		if f.nargs == 1 && .Variadic in f.parameter[0].specialization {
			return vaargs_gen(var, fn)
		}

		if cast(c.int)len(var) != f.nargs {
			perrorf(f.pos, "wrong number of arguments: %d - %d", len(var), f.nargs)
			return nil, false
		}

		inst = new(Code)
		inst.fn = f.fn
		inst.args = make([dynamic]^Element, f.nargs)

		for &arg, i in mem.slice_ptr(f.parameter, cast(int)f.nargs) {
			bind_arg(inst, var, &arg, i) or_return
		}
	}

	return inst, true
}

bind_arg :: proc(inst: ^Code, var: []Element, arg: ^Args, i: int) -> bool {
	value := var[i]
	#partial switch value.type {
	case .List:
		car := value.list.car
		cdr := value.list.cdr

		#partial switch car.type {
		case .Ident:
			nested_fn := get_symbol(car) or_return
			nested := codegen(cdr[:], nested_fn) or_return

			inst.args[i].type = .Code
			inst.args[i].code = nested^
		case .Code:
			inst.args[i].type = .Code
			inst.args[i].code = car.code
		case .Quote:
			inst.args[i] = new_element(.List)
			inst.args[i].list.car = car
			inst.args[i].list.cdr = cdr
		case:
			inst.args[i] = car
		}
	case:
		if arg.type == .Digit && value.type == .Float || value.type == .Integer {
			inst.args[i] = &var[i]
		} else if arg.type == .Any {
			inst.args[i] = &var[i]
		} else if arg.type != value.type {
			return false
		} else {
			inst.args[i] = &var[i]
		}
	}
	return true
}

build :: proc(var: ^Element) -> (^Code, bool) {
	#partial switch var.type {
	case .String, .Float, .Quote, .Integer, .Operator, .Ident:
		inst := new(Code, context.temp_allocator)
		inst.args = make([dynamic]^Element, 1, context.temp_allocator)
		inst.args[0] = var
		return inst, true
	case .List:
		car := var.list.car
		cdr := var.list.cdr
		#partial switch car.type {
		case .Ident:
			fn, ok := global_function_table[string(car.text)]
			if !ok {
				fn, ok = global_function_table[string("shell")]
				if !ok do return nil, false
				inst, ok := codegen(cdr[:], fn)
				if !ok do return nil, false
				inject_at(&inst.args, 0, car)
				return inst, true
			}
			return codegen(cdr[:], fn)
		case .Operator:
			fn, ok :=
				global_function_table[tokenizer.tokens[cast(tokenizer.Token_Kind)car.operator]]
			if ok {
				return codegen(cdr[:], fn)
			}
		case:
			panic("tbd")
		}
	}

	return nil, false
}

eval :: proc(inst: ^Code) -> ^Element {
	if inst == nil do return nil
	if inst.fn == nil {
		if inst.args != nil {
			#partial switch inst.args[0].type {
			case:
				return inst.args[0]
			case .Code:
				return nil
			}
		}
		return nil
	}

	args := make([dynamic]Element)
	defer delete(args)

	for arg in inst.args {
		#partial switch arg.type {
		case:
			append(&args, arg^)

		case .Code:
			result := eval(&arg.code)
			append(&args, result^)
		}
	}

	return inst.fn(cast(c.int)len(args), raw_data(args))
}

math :: proc(op: tokenizer.Token_Kind, x, y: f64) -> f64 {
	#partial switch op {
	case .Add:
		return x + y
	case .Sub:
		return x - y
	case .Mul:
		return x * y
	case .Quo:
		return x / y
	case:
		panic("tbd")
	}
}

get_digit :: proc(e: Element) -> (f64, bool) {
	if e.type == .Float {
		return e.float, true
	} else if e.type == .Integer {
		return cast(f64)e.integer, false
	}
	panic("invalid element")
}

math_proc :: proc(op: tokenizer.Token_Kind, nargs: c.int, args: [^]Element) -> ^Element {
	if nargs == 0 do return nil

	result := new_element(nil)

	sum: f64

	has_float: bool

	if nargs == 1 {
		x: f64
		x, has_float = get_digit(args[0])
		sum = math(op, sum, x)
	} else {
		car: f64

		argv := mem.slice_ptr(args, cast(int)nargs)
		car, has_float = get_digit(argv[0])

		for arg in argv[1:] {
			x, is_float := get_digit(arg)
			car = math(op, car, x)
			if is_float do has_float = true
		}

		sum = car
	}

	if has_float {
		result.type = .Float
		result.float = sum
	} else {
		result.type = .Integer
		result.integer = cast(i64)sum
	}

	return result
}

plus := Compiled_Function {
	fn = plus_proc,
	parameter = &Digit_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

plus_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Add, nargs, args)
}

sub := Compiled_Function {
	fn = sub_proc,
	parameter = &Digit_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

sub_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Sub, nargs, args)
}

mul := Compiled_Function {
	fn = mul_proc,
	parameter = &Digit_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

mul_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Mul, nargs, args)
}

quo := Compiled_Function {
	fn = quo_proc,
	parameter = &Digit_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

quo_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Quo, nargs, args)
}
