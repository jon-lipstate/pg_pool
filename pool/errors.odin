package pg_pool

import pq "../vendor/odin-postgresql"
import "core:mem"
import "core:strings"

// TODO: need cleanup here...
db_error :: proc(kind: DB_Error_Kind, msg: string) -> Error {
	db_err := new(DB_Error)
	db_err^ = DB_Error {
		kind = kind,
		msg  = msg,
	}
	return db_err
}


Error :: union #shared_nil {
	QueryError,
	PoolError,
	mem.Allocator_Error,
	^DB_Error,
}

DB_Error :: struct {
	kind: DB_Error_Kind,
	msg:  string,
}

DB_Error_Kind :: enum {
	InvalidArgument,
	UnknownOID,
	StatementNotPrepared,
	ConnectionError, // Errors with the database connection
	SyntaxError, // SQL query syntax errors
	ConstraintViolation, // Errors like foreign key or unique constraints
	PermissionDenied, // Lack of access rights to perform an operation
	ExecutionError, // General execution failure
	Timeout, // Database query timeout
	UnknownError,
}

QueryError :: enum {
	None,
	FailedToAcquireConnection,
	UnknownType,
	FormattingError,
	OutOfBounds,
	PqErr,
	NoRows,
	UnexpectedNullValue,
	InvalidFormat,
	NotImplemented,
	TypeMismatch,
}

PoolError :: enum {
	None,
	InvalidConnectionString,
	UnableToAcquireConnection,
	InvalidPoolArgs,
	NoResponse,
}

db_error_from_msg :: proc(cnx: ^Connection) -> ^DB_Error {
	error := new(DB_Error)

	// Defensive: a torn-down or never-initialised Connection has cnx.cnx == nil.
	// Some libpq build/version combos also segfault inside PQerrorMessage when
	// the connection's internal state is corrupted (observed on SSL "bad record
	// type" tear-downs from cloud LBs). Returning a typed error here lets the
	// caller log + recover instead of taking the whole worker down.
	if cnx == nil || cnx.cnx == nil {
		error.kind = DB_Error_Kind.ConnectionError
		error.msg  = "connection handle is nil (already destroyed or never opened)"
		return error
	}

	err_msg := pq.error_message(cnx.cnx)
	str: string
	if err_msg != nil do str = strings.clone(string(err_msg))

	// Empty / nil PQ message after a non-nil-result failure means libpq
	// dropped the message buffer (typical on connection-level faults like
	// SSL "bad record type" or mid-flight TCP loss). Surface a clearer
	// reason so the log isn't `msg = ""` and ConnectionError so callers
	// can distinguish from a pure SQL/Exec problem.
	if str == "" {
		error.kind = DB_Error_Kind.ConnectionError
		error.msg  = "no PQ error message — connection likely broken (SSL/TCP fault)"
		return error
	}

	if strings.contains(str, "syntax error") {
		error.kind = DB_Error_Kind.SyntaxError
	} else if strings.contains(str, "constraint") {
		error.kind = DB_Error_Kind.ConstraintViolation
	} else if strings.contains(str, "permission denied") {
		error.kind = DB_Error_Kind.PermissionDenied
	} else if strings.contains(str, "timeout") {
		error.kind = DB_Error_Kind.Timeout
	} else if strings.contains(str, "SSL") || strings.contains(str, "ssl") {
		error.kind = DB_Error_Kind.ConnectionError
	} else {
		error.kind = DB_Error_Kind.ExecutionError
	}
	error.msg = str
	return error
}
