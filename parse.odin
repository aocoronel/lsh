package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strconv"
import "core:strings"
import "tokenizer"

/*
The implementation assumes compatibility with C ABI to support extensions
*/

Parser :: struct {
	token: tokenizer.Token,
	tok:   ^tokenizer.Tokenizer,
}

Element :: struct {
	using u: ^Element_Union,
	type:    Element_Type,
	pos:     tokenizer.Pos,
}

Element_Union :: struct #raw_union {
	list:     List,
	boolean:  bool,
	text:     cstring,
	integer:  c.long,
	float:    c.double,
	operator: c.uint32_t,
	code:     Code,
}

// odinfmt: disable
Element_Type :: enum u32 {
	B_Literal_Begin,
  	List,    // ()
    Bool,    // t or nil
  	String,  // "main"
  	Ident,   // main
  	Quote,   // 'main TODO: have to hack the tokenizer for this
  	Integer, // 69
  	Float,   // 1042.69
    Code,
	B_Literal_End,

  B_Symbol_Begin,
    Function,
    Operator,
  B_Symbol_End,

  B_Parameter_Begin,
	  Any,
	  Digit,
  B_Parameter_End,
}
// odinfmt: enable

List :: struct {
	car: ^Element,
	cdr: [dynamic]Element,
}

Code :: struct {
	next: ^Code,
	fn:   Callback_Proc,
	args: [dynamic]^Element,
}

new_element :: proc(type: Element_Type, allocator := context.temp_allocator) -> ^Element {
	var := new(Element, allocator)
	var.u = new(Element_Union, allocator)
	var.type = type
	return var
}

print_element :: proc(var: ^Element, n: int = 0) {
	if config.debug == false do return
	nn := n + 2

	indent :: proc(n: int) {
		fmt.print(strings.repeat(" ", n, context.temp_allocator))
	}

	indent(n)

	if var == nil {
		fmt.println(nil)
		return
	}

	#partial switch var.type {
	case .String, .Ident, .Quote:
		fmt.println(var.text)
	case .Bool:
		fmt.println(var.boolean ? "t" : "nil")
	case .Float:
		fmt.println(var.float)
	case .Integer:
		fmt.println(var.integer)
	case .List:
		fmt.println("car:")
		print_element(var.list.car, nn)
		indent(n)
		fmt.println("cdr:")
		if var.list.cdr == nil {
			indent(nn)
			fmt.println(nil)
		} else {
			for &v in var.list.cdr {
				print_element(&v, nn)
			}
		}
	case .Operator:
		fmt.println(tokenizer.tokens[var.operator])
	case:
		fmt.println(var)
	}
}

perrorf :: proc(pos: tokenizer.Pos, fmt_str: string, args: ..any, location := #caller_location) {
	log.logf(
		.Error,
		fmt.tprintf("%s:%d: %s", pos.file, pos.line, fmt_str),
		..args,
		location = location,
	)
}

parse_expr :: proc(psr: ^Parser) -> (var: ^Element) {
	var = new_element(.List) // allocation freed at end of loop in main()

	psr.token = tokenizer.scan(psr.tok)
	if psr.token.kind == .Close_Paren {
		return
	}

	car := parse_any(psr)
	if car == nil do return

	var.list.car = car

	for {
		psr.token = tokenizer.scan(psr.tok)
		#partial switch psr.token.kind {
		case .Close_Paren:
			return
		case .Period:
			// (car . cdr)
			psr.token = tokenizer.scan(psr.tok)
			cdr := parse_any(psr)
			if cdr == nil {
				perrorf(psr.token.pos, "expected value for cdr, got <nil>")
				return nil
			}
			append(&var.list.cdr, cdr^)
			psr.token = tokenizer.scan(psr.tok)
			if psr.token.kind != .Close_Paren {
				perrorf(psr.token.pos, "expected ')'")
				return nil
			}
			return
		}
		cdr := parse_any(psr)
		if cdr == nil {
			boolean := new_element(.Bool)
			append(&var.list.cdr, boolean^)
		} else {
			append(&var.list.cdr, cdr^)
		}
	}

	return nil
}

parse_ident :: proc(psr: ^Parser) -> ^Element {
	var := new_element(.Ident)
	var.text = strings.clone_to_cstring(psr.token.text, context.temp_allocator)
	var.pos = psr.token.pos
	return var
}

parse_quote :: proc(psr: ^Parser) -> ^Element {
	token := psr.token.text
	if len(token) == 2 do return nil // ""
	var := new_element(.Quote)
	var.text = strings.clone_to_cstring(token[1:len(token) - 1], context.temp_allocator)
	var.pos = psr.token.pos
	return var
}

parse_string :: proc(psr: ^Parser) -> ^Element {
	token := psr.token.text
	if len(token) == 2 do return nil // ""
	var := new_element(.String)
	var.text = strings.clone_to_cstring(token[1:len(token) - 1], context.temp_allocator)
	var.pos = psr.token.pos
	return var
}

parse_float :: proc(psr: ^Parser) -> ^Element {
	var := new_element(.Float)
	i, _ := strconv.parse_f64(psr.token.text)
	var.float = cast(c.double)i
	var.pos = psr.token.pos
	return var
}

parse_int :: proc(psr: ^Parser) -> ^Element {
	var := new_element(.Integer)
	i, _ := strconv.parse_int(psr.token.text)
	var.integer = cast(c.long)i
	var.pos = psr.token.pos
	return var
}

parse_operator :: proc(psr: ^Parser) -> ^Element {
	var := new_element(.Operator)
	var.operator = cast(c.uint32_t)psr.token.kind
	var.pos = psr.token.pos
	return var
}

parse_any :: proc(psr: ^Parser, loc := #caller_location) -> ^Element {
	#partial switch psr.token.kind {
	case .EOF:
		return nil
	case .Open_Paren:
		return parse_expr(psr)
	case .String:
		return parse_string(psr)
	case .Integer:
		return parse_int(psr)
	case .Ident, .B_Keyword_Begin ..< .B_Keyword_End:
		return parse_ident(psr)
	case .Rune:
		return parse_quote(psr)
	case .Float:
		return parse_float(psr)
	case .B_Operator_Begin ..< .B_Comparison_End:
		return parse_operator(psr)
	case:
		perrorf(
			psr.token.pos,
			"parse_any() isn't responsible for parsing %q. %s:%d",
			psr.token.kind,
			loc.file_path,
			loc.line,
		)
		panic("unreachable")
	}
}

transmute_list :: proc(e: [dynamic]Element) -> (result: [dynamic]Element) {
	if e == nil do return nil
	var := new_element(.List)
	var.list.car = &e[0]
	for i in 1 ..< len(e) {
		append(&var.list.cdr, e[i])
	}
	append(&result, var^)
	return
}

parse :: proc(config: ^Config, line: string, interactive: bool) -> (result: [dynamic]Element) {
	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, line, "")
	psr := Parser {
		tok = &tok,
	}
	for {
		psr.token = tokenizer.scan(&tok)
		element := parse_any(&psr)
		if element == nil {
			if !interactive do return
			if result != nil {
				// if first element is identifier, treat the line like POSIX shell
				if result[0].type != .Ident do return
				return transmute_list(result)
			}
			return
		}
		append(&result, element^)
	}
}
