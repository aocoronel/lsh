#+feature dynamic-literals
package main

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "tokenizer"

// too lazy to learn bufio, so I made a mini one
buffered_read :: proc(sb: ^strings.Builder) -> bool {
	STREAM_SIZE :: 516
	stream: [STREAM_SIZE]byte = ---
	for {
		n, err := os.read(os.stdin, stream[:])
		switch err {
		case nil:
		case:
			log.error(err)
			fallthrough
		case .EOF:
			return false
		}
		strings.write_string(sb, string(stream[:n]))
		if n < STREAM_SIZE do return true
	}
}

// basename :: proc(path: string) -> string {
// 	base := os.base(path)
// 	for i := len(base) - 1; i >= 0 && !os.is_path_separator(base[i]); i -= 1 {
// 		if base[i] == '.' {
// 			return base[:i]
// 		}
// 	}
// 	return base
// }

load_libraries :: proc(config: ^Config, allocator := context.allocator) -> bool {
	files, err := os.read_directory_by_path(config.libdir, -1, allocator)
	defer delete(files)

	if err != nil {
		log.errorf("failed to open directory '%s': %s", config.libdir, os.error_string(err))
		return false
	}

	for file in files {
		fullpath := file.fullpath

		if !strings.ends_with(fullpath, ".so") do continue

		library: dynlib.Library = ---
		lsh: rawptr = ---
		ok: bool = ---

		library, ok = dynlib.load_library(fullpath)
		if !ok {
			log.errorf("failed to load library '%s', skipping", fullpath, dynlib.last_error())
			continue
		}

		lsh, ok = dynlib.symbol_address(library, "lsh_command")
		if !ok {
			log.errorf(
				"library '%s' doesn't have symbol %q, skipping",
				fullpath,
				"lsh_command",
				dynlib.last_error(),
			)
			dynlib.unload_library(library)
			continue
		}

		lsh_proc := cast(Lsh_Plugin_Proc)lsh
		lib := Library{library, lsh_proc()}

		config.plugin[string(lib.plugin.name)] = lib
	}
	return true
}

main :: proc() {
	sb: strings.Builder
	state: mem.Dynamic_Arena

	log.Level_Headers = {
		0 ..< 10 = "debug: ",
		10 ..< 20 = "info: ",
		20 ..< 30 = "warn: ",
		30 ..< 40 = "error: ",
		40 ..< 50 = "fatal: ",
	}
	context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	if len(os.args) == 1 {
		if !os.is_tty(os.stdin) {
			log.error("non interactive is not supported")
			os.exit(1)
		}
	}

	mem.dynamic_arena_init(&state)
	state_allocator := mem.dynamic_arena_allocator(&state)
	defer mem.dynamic_arena_destroy(&state)

	config.debug = get_config("DEBUG", false, allocator = state_allocator)
	config.rprompt = "unused"
	config.memory_threshold = get_config(
		"MEMORY_THRESHOLD",
		cast(int)(1 * 1024 * 1024),
		allocator = state_allocator,
	)
	config.lprompt = get_config("PROMPT", "> ", allocator = state_allocator)
	config.libdir = get_config("LSH_LIBS", "./libs", allocator = state_allocator)

	load_libraries(&config, context.allocator)
	defer {
		for key, &value in config.plugin {
			dynlib.unload_library(value.library)
		}
		delete(config.plugin)
	}

	strings.builder_init(&sb, context.allocator)
	defer strings.builder_destroy(&sb)

	odin_source_code_location_to_tokenizer_pos :: proc(
		loc: runtime.Source_Code_Location,
	) -> tokenizer.Pos {
		return tokenizer.Pos {
			file = loc.file_path,
			line = cast(int)loc.line,
			column = cast(int)loc.column,
		}
	}

	odin_pos :: odin_source_code_location_to_tokenizer_pos

	global_function_table = {
		"defun" = defun,
		"shell" = shell,
		"="     = {},
		"!"     = {},
		"#"     = {},
		"@"     = {},
		"$"     = {},
		"^"     = {},
		"?"     = {},
		"+"     = {plus_proc, &Digit_Variadic, 1, {}},
		"-"     = {sub_proc, &Digit_Variadic, 1, {}},
		"*"     = {mul_proc, &Digit_Variadic, 1, {}},
		"/"     = {quo_proc, &Digit_Variadic, 1, {}},
		"%  "   = {},
		"%% "   = {},
		"&  "   = {},
		"|  "   = {},
		"~  "   = {},
		"&~ "   = {},
		"<< "   = {},
		">> "   = {},
		"&& "   = {},
		"|| "   = {},
		"** "   = {},
		"+= "   = {},
		"-= "   = {},
		"*= "   = {},
		"/= "   = {},
		"%= "   = {},
		"%%="   = {},
		"&= "   = {},
		"|= "   = {},
		"~= "   = {},
		"&~="   = {},
		"<<="   = {},
		">>="   = {},
		"&&="   = {},
		"||="   = {},
		"++ "   = {},
		"-- "   = {},
		"-> "   = {},
		"---"   = {},
		"== "   = {},
		"!= "   = {},
		"<  "   = {},
		">  "   = {},
		"<= "   = {},
		">= "   = {},
		// .Open_Paren    = {}, // (
		// .Close_Paren   = {}, // )
		// .Open_Bracket  = {}, // [
		// .Close_Bracket = {}, // ]
		// .Open_Brace    = {}, // {
		// .Close_Brace   = {}, // }
		// .Colon         = {}, // :
		// .Semicolon     = {}, // ;
		// .Period        = {}, // .
		// .Comma         = {}, // ,
		// .Ellipsis      = {}, // ..
		// .Range_Half    = {}, // ..<
		// .Range_Full    = {}, // ..=
	}

	if len(os.args) > 1 {
		contents, err := os.read_entire_file_from_path(os.args[1], context.allocator)
		defer free(&contents)
		if err != nil {
			log.error(err)
			return
		}

		v := parse(&config, string(contents[:]))

		for &e in v {
			print_element(&e)

			instruction, ok := build(&e)

			result := execute(instruction)

			print_element(result)
		}

		return
	}

	for {
		// Reuse memory
		strings.builder_reset(&sb)

		fmt.print(config.lprompt) // Left Prompt
		// TODO: Right Prompt

		if !buffered_read(&sb) do break

		if len(sb.buf) < 2 do continue

		// All lines contains '\n'
		line := string(sb.buf[:len(sb.buf) - 1])

		v := parse(&config, line)

		for &e in v {
			print_element(&e)

			instruction, ok := build(&e)

			result := execute(instruction)

			print_element(result)
		}

		// If last input was too large, shrink it
		if cap(sb.buf) > config.memory_threshold {
			resize(&sb.buf, config.memory_threshold)
		}

		free_all(context.temp_allocator)
	}
}

