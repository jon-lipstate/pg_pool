package pg_pool

import pq "../vendor/odin-postgresql"
import "core:mem"
import "core:strings"


db_error::proc(kind:DB_Error_Kind, msg:string)->Error{
	db_err:=new(DB_Error)
	db_err^ = DB_Error{
		kind = kind,
		msg = msg,
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
}

PoolError :: enum {
	None,
	InvalidConnectionString,
	UnableToAcquireConnection,
	InvalidPoolArgs,
	NoResponse,
}

db_error_from_msg :: proc(cnx: ^Connection) -> ^DB_Error {
	err_msg := pq.error_message(cnx.cnx)
	error := new(DB_Error)

	if err_msg != nil {
		str := strings.clone(string(err_msg))
		if strings.contains(str, "syntax error") {
			error.kind = DB_Error_Kind.SyntaxError
		} else if strings.contains(str, "constraint") {
			error.kind = DB_Error_Kind.ConstraintViolation
		} else if strings.contains(str, "permission denied") {
			error.kind = DB_Error_Kind.PermissionDenied
		} else if strings.contains(str, "timeout") {
			error.kind = DB_Error_Kind.Timeout
		} else {
			error.kind = DB_Error_Kind.ExecutionError
		}
		error.msg = str
		return error
	}

	error.kind = DB_Error_Kind.UnknownError
	error.msg = "Nil PQ-Result with no error message"
	return error
}
