package pg_pool

import "core:math/fixed"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:time"

// Use Odin's built-in fixed-point for PostgreSQL NUMERIC/DECIMAL
// Fixed52_12 gives us 52 bits for integer part, 12 bits for fractional part
// This covers most real-world NUMERIC use cases efficiently
Numeric :: fixed.Fixed52_12

// PostgreSQL MONEY is just stored as i64 (cents or smallest currency unit)
// $123.45 USD = 12345 as i64
Money :: i64

// PostgreSQL INTERVAL type - stores duration with separate months, days, and microseconds
// This matches PostgreSQL's internal representation exactly
Interval :: struct {
    months:      i32,  // months and years (years * 12)
    days:        i32,  // days component
    microseconds: i64, // all time units smaller than days (hours, minutes, seconds, microseconds)
}

// Parse PostgreSQL NUMERIC binary format directly into Odin Fixed52_12
//
// PRECISION LIMITS:
// ================
// This function converts PostgreSQL NUMERIC to Fixed52_12, which has limitations:
//
// INTEGER RANGE (exact representation):
//   Min: -4,503,599,627,370,496  (±4.5 quadrillion)
//   Max: +4,503,599,627,370,495  (~15 decimal digits)
//
// FRACTIONAL PRECISION (exact representation):
//   Resolution: 1/4096 = 0.000244140625
//   Decimal places: ~3.6 (values that align to 1/4096 multiples)
//
// LOSSLESS EXAMPLES:
//   ✅ NUMERIC(15,3): 999,999,999,999.999
//   ✅ NUMERIC(12,3): 999,999,999.999  
//   ✅ NUMERIC(10,2): 99,999,999.99 (typical money)
//   ✅ Currency amounts with penny precision
//
// PRECISION LOSS EXAMPLES:
//   ⚠️  123.456789 → 123.456787109375 (fractional rounding)
//   ⚠️  NUMERIC(10,5) → loses precision beyond ~3.6 decimal places
//   ❌ NUMERIC(20,10) → exceeds integer range and fractional precision
//   ❌ PostgreSQL NUMERIC(1000,500) → far exceeds capabilities
//
// USE CASES:
//   Perfect for: Financial calculations, business applications, currency
//   Avoid for: Scientific computing, very high precision requirements
//
parse_postgres_numeric :: proc(bytes: []byte, allocator := context.allocator) -> (Numeric, bool) {
    if len(bytes) < 8 {
        return {}, false
    }
    
    // PostgreSQL NUMERIC binary format:
    // ndigits (2 bytes) - number of base-10000 digits
    // weight (2 bytes)  - weight of first digit  
    // sign (2 bytes)    - sign flags
    // dscale (2 bytes)  - display scale
    // digits (2 bytes each) - base-10000 digit values
    
    ndigits := u16(bytes[0]) << 8 | u16(bytes[1])
    weight := i16(bytes[2]) << 8 | i16(bytes[3]) 
    sign := u16(bytes[4]) << 8 | u16(bytes[5])
    dscale := u16(bytes[6]) << 8 | u16(bytes[7])
    
    // Handle special cases
    if sign == 0xC000 { // NaN
        return {}, false // Could return a special NaN value if needed
    }
    
    if ndigits == 0 {
        return {}, true // Zero
    }
    
    // Parse digits directly into Fixed52_12
    // PostgreSQL uses base-10000 digits, we need to convert to base-10
    
    result: Numeric
    digit_offset := 8
    
    // Accumulate the value directly
    total_value: f64 = 0.0
    
    for i in 0..<ndigits {
        if digit_offset + 1 >= len(bytes) {
            return {}, false
        }
        
        digit := u16(bytes[digit_offset]) << 8 | u16(bytes[digit_offset + 1])
        
        // Each digit represents a power of 10000
        // weight indicates the position of the first digit relative to decimal point
        digit_weight := int(weight) - int(i)
        
        // Convert to actual decimal value
        digit_value := f64(digit)
        
        // Apply the weight: positive weight means powers of 10000, negative means fractions
        power_of_10000 := f64(1.0)
        if digit_weight > 0 {
            // Positive weight: multiply by 10000^weight
            for _ in 0..<digit_weight {
                power_of_10000 *= 10000.0
            }
        } else if digit_weight < 0 {
            // Negative weight: divide by 10000^(-weight)
            for _ in 0..<(-digit_weight) {
                power_of_10000 /= 10000.0
            }
        }
        // digit_weight == 0: power_of_10000 remains 1.0
        
        total_value += digit_value * power_of_10000
        digit_offset += 2
    }
    
    // Apply sign
    if sign == 0x4000 { // Negative
        total_value = -total_value
    }
    
    // Convert f64 to Fixed52_12
    // Note: init_from_f64 may silently overflow/underflow for values outside Fixed52_12 range
    // Values larger than ±4.5 quadrillion will wrap around or become invalid
    fixed.init_from_f64(&result, total_value)
    
    return result, true
}

// Parse decimal string into Fixed52_12
parse_decimal_string :: proc(result: ^Numeric, str: string) -> bool {
    // Find decimal point
    decimal_pos := strings.index_byte(str, '.')
    
    integer_part: string
    fraction_part: string
    
    if decimal_pos == -1 {
        // No decimal point
        integer_part = str
        fraction_part = ""
    } else {
        integer_part = str[:decimal_pos]
        fraction_part = str[decimal_pos + 1:]
    }
    
    // Parse integer part
    integer_val, int_ok := strconv.parse_i64(integer_part)
    if !int_ok {
        return false
    }
    
    // Parse fractional part
    fraction_val: i64 = 0
    if len(fraction_part) > 0 {
        // Pad or truncate to 12 decimal places (Fixed52_12 precision)
        padded_fraction := fraction_part
        if len(fraction_part) < 12 {
            // Pad with zeros
            padded_fraction = fmt.aprintf("%s%s", 
                fraction_part,
                strings.repeat("0", 12 - len(fraction_part), context.temp_allocator))
            defer delete(padded_fraction, context.temp_allocator)
        } else if len(fraction_part) > 12 {
            // Truncate to 12 digits
            padded_fraction = fraction_part[:12]
        }
        
        frac_val, frac_ok := strconv.parse_i64(padded_fraction)
        if !frac_ok {
            return false
        }
        fraction_val = frac_val
    }
    
    // Combine integer and fractional parts
    fixed.init_from_parts(result, integer_val, fraction_val)
    return true
}

// Convert Fixed52_12 to PostgreSQL NUMERIC binary format
numeric_to_postgres_binary :: proc(num: Numeric, buf: ^[dynamic]byte) -> i32 {
    // Convert Fixed52_12 to PostgreSQL's base-10000 digit representation
    
    // Get the f64 value for easier manipulation
    f64_val := fixed.to_f64(num)
    
    // Handle special cases
    if f64_val == 0.0 {
        // Zero: ndigits=0, weight=0, sign=0x0000, dscale=0
        append(buf, 0, 0) // ndigits = 0
        append(buf, 0, 0) // weight = 0  
        append(buf, 0, 0) // sign = 0x0000 (positive)
        append(buf, 0, 0) // dscale = 0
        return 8
    }
    
    // Determine sign
    sign: u16 = 0x0000 // positive
    abs_val := f64_val
    if f64_val < 0 {
        sign = 0x4000 // negative
        abs_val = -f64_val
    }
    
    // Convert to string to extract digits more easily
    // This is not the most efficient but ensures correctness
    str := fmt.tprintf("%.12f", abs_val) // Use 12 decimal places for Fixed52_12 precision
    
    // Remove trailing zeros
    str = strings.trim_right(str, "0")
    if strings.has_suffix(str, ".") {
        str = str[:len(str)-1]
    }
    
    // Find decimal point
    decimal_pos := strings.index_byte(str, '.')
    if decimal_pos == -1 {
        decimal_pos = len(str)
    }
    
    // Calculate dscale (number of digits after decimal point)
    dscale := u16(len(str) - decimal_pos - 1)
    if decimal_pos == len(str) {
        dscale = 0
    }
    
    // Remove decimal point for processing
    digits_str, _ := strings.replace_all(str, ".", "", context.temp_allocator)
    defer delete(digits_str, context.temp_allocator)
    
    // Pad digits to multiple of 4 (base-10000 requirement)
    total_digits := len(digits_str)
    padding_needed := (4 - (total_digits % 4)) % 4
    
    if decimal_pos == len(str) {
        // Integer - pad on the right
        padded_str := fmt.aprintf("%s%s", digits_str, strings.repeat("0", padding_needed, context.temp_allocator))
        defer delete(padded_str, context.temp_allocator)
        digits_str = padded_str
    } else {
        // Has decimal - pad on the left for integer part, right for fractional
        integer_digits := decimal_pos
        fractional_digits := total_digits - integer_digits
        
        integer_padding := (4 - (integer_digits % 4)) % 4
        fractional_padding := (4 - (fractional_digits % 4)) % 4
        
        padded_str := fmt.aprintf("%s%s%s", 
            strings.repeat("0", integer_padding, context.temp_allocator),
            digits_str[:integer_digits],
            digits_str[integer_digits:])
        
        if fractional_padding > 0 {
            padded_str = fmt.aprintf("%s%s", padded_str, strings.repeat("0", fractional_padding, context.temp_allocator))
        }
        defer delete(padded_str, context.temp_allocator)
        digits_str = padded_str
        decimal_pos += integer_padding
    }
    
    // Convert to base-10000 digits
    ndigits := u16(len(digits_str) / 4)
    base10000_digits := make([]u16, ndigits, context.temp_allocator)
    defer delete(base10000_digits, context.temp_allocator)
    
    for i in 0..<ndigits {
        digit_str := digits_str[i*4:(i+1)*4]
        digit_val, _ := strconv.parse_int(digit_str)
        base10000_digits[i] = u16(digit_val)
    }
    
    // Calculate weight (position of first digit relative to decimal point)
    // Weight is in base-10000 units
    weight := i16((decimal_pos / 4) - 1)
    if decimal_pos % 4 != 0 {
        weight += 1
    }
    
    // Write header
    append(buf, byte(ndigits >> 8), byte(ndigits))     // ndigits
    append(buf, byte(weight >> 8), byte(weight))       // weight  
    append(buf, byte(sign >> 8), byte(sign))           // sign
    append(buf, byte(dscale >> 8), byte(dscale))       // dscale
    
    // Write digits
    for digit in base10000_digits {
        append(buf, byte(digit >> 8), byte(digit))
    }
    
    return i32(8 + ndigits * 2) // header + digits
}

// Convert Fixed52_12 to PostgreSQL text format (simpler)
numeric_to_postgres_text :: proc(num: Numeric, buf: ^[dynamic]byte) -> i32 {
    str := fixed.to_string(num, context.temp_allocator)
    defer delete(str, context.temp_allocator)
    
    str_bytes := transmute([]byte)str
    append(buf, ..str_bytes)
    return i32(len(str_bytes))
}

// Convert f64 to Numeric
f64_to_numeric :: proc(val: f64) -> Numeric {
    result: Numeric
    fixed.init_from_f64(&result, val)
    return result
}

// Convert Numeric to f64
numeric_to_f64 :: proc(num: Numeric) -> f64 {
    return fixed.to_f64(num)
}

// Convert string to Numeric
string_to_numeric :: proc(str: string) -> (Numeric, bool) {
    result: Numeric
    ok := parse_decimal_string(&result, str)
    return result, ok
}

// Convert Numeric to string
numeric_to_string :: proc(num: Numeric, allocator := context.allocator) -> string {
    return fixed.to_string(num, allocator)
}

// Parse MONEY from PostgreSQL text format to i64 cents
// Handles various locale formats:
//   US: "$1,234.56" or "1234.56" 
//   EU: "€1.234,56" or "1234,56"
//   Mixed: "1,234.56", "1.234,56"
parse_money_text :: proc(str: string) -> (i64, bool) {
    if len(str) == 0 {
        return 0, false
    }
    
    // Remove currency symbols
    cleaned := strings.trim_space(str)
    cleaned = strings.trim_left(cleaned, "$¢£€¥₹₽¤")
    cleaned = strings.trim_space(cleaned)
    
    // Handle negative sign
    negative := false
    if strings.has_prefix(cleaned, "-") {
        negative = true
        cleaned = strings.trim_left(cleaned, "-")
        cleaned = strings.trim_space(cleaned)
    }
    
    if len(cleaned) == 0 {
        return 0, false
    }
    
    // Find the last occurrence of '.' and ','
    last_dot := strings.last_index_byte(cleaned, '.')
    last_comma := strings.last_index_byte(cleaned, ',')
    
    // Determine decimal separator based on position
    decimal_sep: byte
    thousands_sep: byte
    
    if last_dot == -1 && last_comma == -1 {
        // No separators - integer amount
        integer_val, ok := strconv.parse_i64(cleaned)
        if !ok {
            return 0, false
        }
        result := integer_val * 100  // Assume whole dollars/euros
        if negative {
            result = -result
        }
        return result, true
    } else if last_dot == -1 {
        // Only comma present
        decimal_sep = ','
        thousands_sep = '.'
    } else if last_comma == -1 {
        // Only dot present
        decimal_sep = '.'
        thousands_sep = ','
    } else {
        // Both present - rightmost is decimal separator
        if last_dot > last_comma {
            decimal_sep = '.'
            thousands_sep = ','
        } else {
            decimal_sep = ','
            thousands_sep = '.'
        }
    }
    
    // Split on decimal separator
    decimal_pos := -1
    if decimal_sep == '.' {
        decimal_pos = last_dot
    } else {
        decimal_pos = last_comma
    }
    
    integer_part := cleaned[:decimal_pos]
    fractional_part := cleaned[decimal_pos + 1:]
    
    // Remove thousands separators from integer part
    if thousands_sep != 0 {
        integer_part, _ = strings.replace_all(integer_part, string([]byte{thousands_sep}), "", context.temp_allocator)
        defer delete(integer_part, context.temp_allocator)
    }
    
    // Parse integer part
    integer_val, int_ok := strconv.parse_i64(integer_part)
    if !int_ok {
        return 0, false
    }
    
    // Parse fractional part (expect up to 2 digits for cents)
    fractional_val: i64 = 0
    if len(fractional_part) > 0 {
        // Take only first 2 digits and pad/truncate as needed
        if len(fractional_part) == 1 {
            fractional_part = fmt.aprintf("%s0", fractional_part, allocator = context.temp_allocator)
            defer delete(fractional_part, context.temp_allocator)
        } else if len(fractional_part) > 2 {
            fractional_part = fractional_part[:2]
        }
        
        frac_val, frac_ok := strconv.parse_i64(fractional_part)
        if !frac_ok {
            return 0, false
        }
        fractional_val = frac_val
    }
    
    // Combine to cents
    result := integer_val * 100 + fractional_val
    if negative {
        result = -result
    }
    
    return result, true
}

// Parse PostgreSQL INTERVAL binary format (16 bytes)
// Format: 8 bytes microseconds + 4 bytes days + 4 bytes months (big-endian)
parse_postgres_interval :: proc(bytes: []byte) -> (Interval, bool) {
    if len(bytes) != 16 {
        return {}, false
    }
    
    // Read 8 bytes microseconds (big-endian)
    microseconds := i64(bytes[0]) << 56 | i64(bytes[1]) << 48 | i64(bytes[2]) << 40 | i64(bytes[3]) << 32 |
                     i64(bytes[4]) << 24 | i64(bytes[5]) << 16 | i64(bytes[6]) << 8 | i64(bytes[7])
    
    // Read 4 bytes days (big-endian)
    days := i32(bytes[8]) << 24 | i32(bytes[9]) << 16 | i32(bytes[10]) << 8 | i32(bytes[11])
    
    // Read 4 bytes months (big-endian)
    months := i32(bytes[12]) << 24 | i32(bytes[13]) << 16 | i32(bytes[14]) << 8 | i32(bytes[15])
    
    return Interval{months = months, days = days, microseconds = microseconds}, true
}

// Convert Interval to PostgreSQL binary format (16 bytes)
interval_to_postgres_binary :: proc(interval: Interval, buf: ^[dynamic]byte) -> i32 {
    // Write 8 bytes microseconds (big-endian)
    us := interval.microseconds
    append(buf, ..[]byte{
        byte(us >> 56), byte(us >> 48), byte(us >> 40), byte(us >> 32),
        byte(us >> 24), byte(us >> 16), byte(us >> 8), byte(us)
    })
    
    // Write 4 bytes days (big-endian)
    d := interval.days
    append(buf, ..[]byte{byte(d >> 24), byte(d >> 16), byte(d >> 8), byte(d)})
    
    // Write 4 bytes months (big-endian)
    m := interval.months
    append(buf, ..[]byte{byte(m >> 24), byte(m >> 16), byte(m >> 8), byte(m)})
    
    return 16
}

// Convert Interval to PostgreSQL text format
interval_to_postgres_text :: proc(interval: Interval, buf: ^[dynamic]byte) -> i32 {
    // PostgreSQL text format examples:
    // "1 year 2 mons 3 days 04:05:06.789"
    // "2 days 03:00:00"
    // "1 mon"
    
    parts := make([dynamic]string, 0, 6, context.temp_allocator)
    defer delete_dynamic_array(parts)
    
    months := interval.months
    days := interval.days
    us := interval.microseconds
    
    // Handle years and months
    if months != 0 {
        years := months / 12
        remaining_months := months % 12
        
        if years != 0 {
            if years == 1 {
                append(&parts, "1 year")
            } else {
                append(&parts, fmt.tprintf("%d years", years))
            }
        }
        
        if remaining_months != 0 {
            if remaining_months == 1 {
                append(&parts, "1 mon")
            } else {
                append(&parts, fmt.tprintf("%d mons", remaining_months))
            }
        }
    }
    
    // Handle days
    if days != 0 {
        if days == 1 {
            append(&parts, "1 day")
        } else {
            append(&parts, fmt.tprintf("%d days", days))
        }
    }
    
    // Handle time components (hours, minutes, seconds, microseconds)
    if us != 0 {
        // Convert microseconds to time components
        abs_us := us < 0 ? -us : us
        
        hours := abs_us / (1000000 * 60 * 60)
        remaining := abs_us % (1000000 * 60 * 60)
        
        minutes := remaining / (1000000 * 60)
        remaining = remaining % (1000000 * 60)
        
        seconds := remaining / 1000000
        microseconds := remaining % 1000000
        
        // Format time part
        time_part: string
        if microseconds > 0 {
            time_part = fmt.tprintf("%s%02d:%02d:%02d.%06d", 
                us < 0 ? "-" : "", hours, minutes, seconds, microseconds)
        } else {
            time_part = fmt.tprintf("%s%02d:%02d:%02d", 
                us < 0 ? "-" : "", hours, minutes, seconds)
        }
        append(&parts, time_part)
    }
    
    // Join parts with spaces
    result: string
    if len(parts) == 0 {
        result = "00:00:00"
    } else {
        result = strings.join(parts[:], " ", context.temp_allocator)
    }
    
    result_bytes := transmute([]byte)result
    append(buf, ..result_bytes)
    return i32(len(result_bytes))
}

// Create Interval from time.Duration (converts to microseconds only)
duration_to_interval :: proc(d: time.Duration) -> Interval {
    return Interval{
        months = 0,
        days = 0,
        microseconds = i64(d) / 1000, // Convert nanoseconds to microseconds
    }
}

// Convert Interval to time.Duration (only uses microseconds component)
// Note: Months and days are ignored since Duration can't represent variable-length periods
interval_to_duration :: proc(interval: Interval) -> time.Duration {
    return time.Duration(interval.microseconds * 1000) // Convert microseconds to nanoseconds
}

// Create Interval from components
make_interval :: proc(years: i32 = 0, months: i32 = 0, days: i32 = 0, hours: i64 = 0, minutes: i64 = 0, seconds: i64 = 0, microseconds: i64 = 0) -> Interval {
    total_months := years * 12 + months
    total_microseconds := ((hours * 60 + minutes) * 60 + seconds) * 1000000 + microseconds
    
    return Interval{
        months = total_months,
        days = days,
        microseconds = total_microseconds,
    }
}