package main

import "core:log"
import "core:os"
import "core:strconv"

Config :: struct {
	lprompt, rprompt: string,
	memory_threshold: int,
	debug:            bool,
	libdir:           string,
	plugin:           map[string]Library,
}

config: Config

get_config :: proc {
	get_string_env,
	get_int_env,
	get_bool_env,
}

get_string_env :: proc(
	name, default: string,
	config := config,
	allocator := context.allocator,
) -> string {
	env := os.get_env(name, allocator)
	if len(env) == 0 do return default
	return env
}

get_int_env :: proc(
	name: string,
	default: int,
	config := config,
	allocator := context.allocator,
) -> int {
	env := os.get_env(name, allocator)
	if len(env) == 0 {
		return default
	}
	value, ok := strconv.parse_int(env)
	if !ok && config.debug {
		log.debugf("%s: failed to parse integer: '%s', falling back to '%d'", name, env, default)
	}
	return value
}

get_bool_env :: proc(
	name: string,
	default: bool,
	config := config,
	allocator := context.allocator,
) -> bool {
	env := os.get_env(name, allocator)
	if len(env) == 0 {
		return default
	}
	value, ok := strconv.parse_bool(env)
	if !ok && config.debug {
		log.debugf("%s: failed to parse bool: '%s', falling back to '%d'", name, env, default)
	}
	return value
}

