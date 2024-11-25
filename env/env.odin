package env

import "core:fmt"
import "core:os"
import "core:strings"

set :: proc() -> (ok: bool) {
	env_file := ".env"
	file, read_ok := os.read_entire_file(env_file)
	if !read_ok {return false}
	defer delete(file)
	lines := strings.split(string(file), "\n");defer delete(lines)

	for line in lines {
		trimmed_line := strings.trim(line, "\r\n \t")
		if len(trimmed_line) == 0 || trimmed_line[0] == '#' {continue}

		eq_index := strings.index(trimmed_line, "=")
		if eq_index == -1 {
			fmt.eprintln("Malformed Line: Missing '=', skipping:", trimmed_line)
			continue
		}

		key := strings.trim(trimmed_line[:eq_index], " \t")
		value := strings.trim(trimmed_line[eq_index + 1:], " \t")

		if len(key) == 0 {
			fmt.eprintln("Invalid key found, skipping line:", trimmed_line)
			continue
		}

		err := os.set_env(key, value)
		if err != nil {
			fmt.eprintln("Failed to set env var", key, ":", err)
			return false
		}
	}
	return true
}
