#+feature dynamic-literals

package main

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "shared:odd/pipe"
import "tokenizer"

Pipe :: pipe.Pipe
sh :: pipe.run_command

Instruction_Arg :: union {
	^Element,
	^Instruction,
}

Instruction :: struct {
	next: ^Instruction,
	fn:   Callback_Proc,
	args: [dynamic]Instruction_Arg,
}

Function_Type :: enum {
	Callback,
}

Function :: struct {
	fn:        Callback_Proc,
	parameter: [^]Args,
	nargs:     c.int,
	pos:       tokenizer.Pos,
}

Arg_Specialization :: enum {
	Variadic = 1,
	Optional = 2,
}

Args :: struct {
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

functions: map[string]Function
operators: map[tokenizer.Token_Kind]Function

Digit_Variadic := Args{.Digit, {.Variadic}}
Any_Variadic := Args{.Any, {.Variadic}}

defun := Function {
	fn = defun_proc,
	parameter = &Digit_Variadic,
	nargs = 1,
	pos = {file = "builtin"},
}

defun_exec_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return nil
}

defun_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	assert(nargs > 0)
	name := args[0]
	assert(name.type == .Ident)
	fmt.println("function name =", name.text)
	return nil
}

shell := Function {
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

vaargs_gen :: proc(var: [dynamic]Element, fn: Function) -> (inst: ^Instruction, ok: bool) {
	inst = new(Instruction)
	inst.fn = fn.fn
	inst.args = make([dynamic]Instruction_Arg, len(var))
	arg := fn.parameter[0]
	for i in 0 ..< len(var) {
		bind_arg(inst, var, &arg, i) or_return
	}
	return inst, true
}

get_symbol :: proc(var: ^Element) -> (Function, bool) {
	if var.type == .Ident {
		return functions[string(var.text)]
	} else if var.type == .Operator {
		return operators[cast(tokenizer.Token_Kind)var.operator]
	} else {
		return Function{}, false
	}
}

codegen :: proc(var: [dynamic]Element, fn: Function) -> (inst: ^Instruction, ok: bool) {
	if fn.nargs == 1 && .Variadic in fn.parameter[0].specialization {
		return vaargs_gen(var, fn)
	}

	if cast(c.int)len(var) != fn.nargs {
		perrorf(fn.pos, "wrong number of arguments: %d - %d", len(var), fn.nargs)
		return nil, false
	}

	inst = new(Instruction)
	inst.fn = fn.fn
	inst.args = make([dynamic]Instruction_Arg, fn.nargs)

	for &arg, i in mem.slice_ptr(fn.parameter, cast(int)fn.nargs) {
		bind_arg(inst, var, &arg, i) or_return
	}

	return inst, true
}

bind_arg :: proc(inst: ^Instruction, var: [dynamic]Element, arg: ^Args, i: int) -> bool {
	value := var[i]
	#partial switch value.type {
	case .List:
		car := value.list.car
		cdr := value.list.cdr

		nested_fn := get_symbol(car) or_return
		nested := codegen(cdr, nested_fn) or_return

		inst.args[i] = nested
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

build :: proc(var: ^Element) -> (^Instruction, bool) {
	#partial switch var.type {
	case .String, .Float, .Quote, .Integer, .Operator, .Ident:
		inst := new(Instruction, context.temp_allocator)
		inst.args = make([dynamic]Instruction_Arg, 1, context.temp_allocator)
		inst.args[0] = var
		return inst, true
	case .List:
		car := var.list.car
		cdr := var.list.cdr
		#partial switch car.type {
		case .Ident:
			fn, ok := functions[string(car.text)]
			if !ok {
				fn, ok = functions[string("shell")]
				if !ok do return nil, false
				inst, ok := codegen(cdr, fn)
				if !ok do return nil, false
				inject_at(&inst.args, 0, car)
				return inst, true
			}
			return codegen(cdr, fn)
		case .Operator:
			fn, ok := operators[cast(tokenizer.Token_Kind)car.operator]
			if ok {
				return codegen(cdr, fn)
			}
		case:
			panic("tbd")
		}
	}

	return nil, false
}

execute :: proc(inst: ^Instruction) -> ^Element {
	if inst == nil do return nil
	if inst.fn == nil {
		if inst.args != nil {
			switch a in inst.args[0] {
			case ^Element:
				return a
			case ^Instruction:
				return nil
			}
		}
		return nil
	}

	args := make([dynamic]Element)

	for arg in inst.args {
		switch v in arg {
		case ^Element:
			append(&args, v^)

		case ^Instruction:
			result := execute(v)
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

	result := new_element()

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

plus_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Add, nargs, args)
}

sub_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Sub, nargs, args)
}

mul_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Mul, nargs, args)
}

quo_proc :: proc(nargs: c.int, args: [^]Element) -> ^Element {
	return math_proc(.Quo, nargs, args)
}

