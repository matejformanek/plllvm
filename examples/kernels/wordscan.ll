; wordscan(doc text) STRICT    (phase 2 of bench/kernels/31_tokenize.sql)
;
;   line := doc || ' ';
;   len := length(line);
;   tok := ''; innum := false; num := 0; pos := 1;
;   WHILE pos <= len LOOP
;     c := substr(line, pos, 1);
;     IF position(c IN letters) > 0 THEN
;       tok := tok || c;
;     ELSIF c >= '0' AND c <= '9' THEN
;       innum := true;
;       num := num * 10 + (ascii(c) - 48);
;     ELSE
;       IF tok <> '' THEN
;         nwords := nwords + 1;
;         IF upper(substr(tok, 1, 1)) = substr(tok, 1, 1) THEN
;           ncap := ncap + 1;
;         END IF;
;         tok := lower(tok);
;         IF position(' ' || tok || ' ' IN stop) > 0 THEN
;           nstop := nstop + 1;
;         END IF;
;         IF length(tok) > longest THEN
;           longest := length(tok);
;         END IF;
;         h := (h * 131 + length(tok) * 17 + ascii(tok)) % 1000000007;
;         tok := '';
;       END IF;
;       IF innum THEN
;         nnum := nnum + 1;
;         numsum := numsum + num;
;         h := (h * 131 + num % 1000) % 1000000007;
;         num := 0;
;         innum := false;
;       END IF;
;       IF c <> ' ' THEN
;         npunct := npunct + 1;
;         h := (h * 131 + ascii(c)) % 1000000007;
;       END IF;
;     END IF;
;     pos := pos + 1;
;   END LOOP;
;   RETURN nwords || '/' || ncap || '/' || nstop || '/' || nnum || '/' || numsum || '/'
;          || npunct || '/' || longest || '/' || h;
;
; with letters = [a-zA-Z] and stop = ' the and of on al de '.  tokenize scans
; each of its lines plus ' ' with fresh state; the ' ' flushes all of it, so
; one scan of the lines joined by ' ' gives the same result.
;
; The scan is over bytes, so the text must be ASCII (0A000 otherwise); for it,
; upper(), lower() and the comparisons with '0' and '9' are those of any
; ASCII-compatible locale.  tok is not built: a flush needs only its length,
; its first letter and, for the stop words, its first three letters lowered.

@msg.ascii = private unnamed_addr constant [36 x i8] c"wordscan_ll accepts ASCII text only\00"

declare i64 @plllvm_arg_i64(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_rt_int_overflow() noreturn
declare void @plllvm_rt_bigint_overflow() noreturn
declare i64 @plllvm_cstring_to_text(ptr)
declare i64 @plllvm_detoast(i64)
declare ptr @plllvm_vardata_any(i64)
declare i32 @plllvm_varsize_any_exhdr(i64)
declare i32 @pg_ltoa(i32, ptr)
declare i32 @pg_lltoa(i64, ptr)

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare { i32, i1 } @llvm.smul.with.overflow.i32(i32, i32)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)

define i64 @f(ptr %fcinfo) {
entry:
  %tok.len = alloca i32
  %tok.first = alloca i8
  %tok.key = alloca i32               ; up to 3 letters lowered, one per byte
  %innum = alloca i1
  %num = alloca i64
  %nwords = alloca i32
  %ncap = alloca i32
  %nstop = alloca i32
  %nnum = alloca i32
  %npunct = alloca i32
  %longest = alloca i32
  %numsum = alloca i64
  %h = alloca i64
  %buf = alloca [128 x i8]
  store i32 0, ptr %tok.len
  store i8 0, ptr %tok.first
  store i32 0, ptr %tok.key
  store i1 false, ptr %innum
  store i64 0, ptr %num
  store i32 0, ptr %nwords
  store i32 0, ptr %ncap
  store i32 0, ptr %nstop
  store i32 0, ptr %nnum
  store i32 0, ptr %npunct
  store i32 0, ptr %longest
  store i64 0, ptr %numsum
  store i64 7, ptr %h

  %arg = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %doc = call i64 @plllvm_detoast(i64 %arg)
  %data = call ptr @plllvm_vardata_any(i64 %doc)
  %len.32 = call i32 @plllvm_varsize_any_exhdr(i64 %doc)
  %len = zext i32 %len.32 to i64
  br label %scan

scan:
  %pos = phi i64 [ 0, %entry ], [ %pos.next, %next ]
  %at.end = icmp eq i64 %pos, %len
  br i1 %at.end, label %flush, label %byte

byte:
  %p = getelementptr inbounds i8, ptr %data, i64 %pos
  %c = load i8, ptr %p
  %ascii = icmp sge i8 %c, 0
  br i1 %ascii, label %classify, label %not_ascii

classify:
  %c.lower = or i8 %c, 32
  %c.l = sub i8 %c.lower, 97
  %is.letter = icmp ult i8 %c.l, 26
  br i1 %is.letter, label %letter, label %not_letter

letter:
  ; tok := tok || c
  %tl = load i32, ptr %tok.len
  %is.first = icmp eq i32 %tl, 0
  %first.0 = load i8, ptr %tok.first
  %first.1 = select i1 %is.first, i8 %c, i8 %first.0
  store i8 %first.1, ptr %tok.first
  %key.0 = load i32, ptr %tok.key
  %key.1 = shl i32 %key.0, 8
  %c.lower.32 = zext i8 %c.lower to i32
  %key.2 = or i32 %key.1, %c.lower.32
  %short = icmp ult i32 %tl, 3
  %key.3 = select i1 %short, i32 %key.2, i32 %key.0
  store i32 %key.3, ptr %tok.key
  ; bounded by the length of a varlena
  %tl.next = add nuw nsw i32 %tl, 1
  store i32 %tl.next, ptr %tok.len
  br label %next

not_letter:
  %c.d = sub i8 %c, 48
  %is.digit = icmp ult i8 %c.d, 10
  br i1 %is.digit, label %digit, label %flush

digit:
  ; num := num * 10 + (ascii(c) - 48)
  store i1 true, ptr %innum
  %num.0 = load i64, ptr %num
  %num.1 = call i64 @int8mul(i64 %num.0, i64 10)
  %c.d.64 = zext i8 %c.d to i64
  %num.2 = call i64 @int8pl(i64 %num.1, i64 %c.d.64)
  store i64 %num.2, ptr %num
  br label %next

flush:
  ; the trailing ' ' of doc || ' ' comes from %scan
  %sc = phi i8 [ 32, %scan ], [ %c, %not_letter ]
  %last = phi i1 [ true, %scan ], [ false, %not_letter ]
  %tl.f = load i32, ptr %tok.len
  %has.tok = icmp ne i32 %tl.f, 0
  br i1 %has.tok, label %word, label %number.test

word:
  %nwords.0 = load i32, ptr %nwords
  %nwords.1 = call i32 @int4pl(i32 %nwords.0, i32 1)
  store i32 %nwords.1, ptr %nwords
  %first = load i8, ptr %tok.first
  %first.u = sub i8 %first, 65
  %is.cap = icmp ult i8 %first.u, 26
  %cap = zext i1 %is.cap to i32
  %ncap.0 = load i32, ptr %ncap
  %ncap.1 = call i32 @int4pl(i32 %ncap.0, i32 %cap)
  store i32 %ncap.1, ptr %ncap
  ; a stop word is (length << 32) | its letters
  %tl.64 = zext i32 %tl.f to i64
  %tl.hi = shl i64 %tl.64, 32
  %key = load i32, ptr %tok.key
  %key.64 = zext i32 %key to i64
  %word.key = or i64 %tl.hi, %key.64
  switch i64 %word.key, label %word.rest [
    i64 8589963110, label %stop             ; of
    i64 8589963118, label %stop             ; on
    i64 8589959532, label %stop             ; al
    i64 8589960293, label %stop             ; de
    i64 12892530789, label %stop            ; the
    i64 12891287140, label %stop            ; and
  ]

stop:
  %nstop.0 = load i32, ptr %nstop
  %nstop.1 = call i32 @int4pl(i32 %nstop.0, i32 1)
  store i32 %nstop.1, ptr %nstop
  br label %word.rest

word.rest:
  %longest.0 = load i32, ptr %longest
  %longer = icmp sgt i32 %tl.f, %longest.0
  %longest.1 = select i1 %longer, i32 %tl.f, i32 %longest.0
  store i32 %longest.1, ptr %longest
  ; h := (h * 131 + length(tok) * 17 + ascii(tok)) % 1000000007
  %h.w0 = load i64, ptr %h
  %h.w1 = call i64 @int8mul(i64 %h.w0, i64 131)
  %len17 = call i32 @int4mul(i32 %tl.f, i32 17)
  %len17.64 = sext i32 %len17 to i64
  %h.w2 = call i64 @int8pl(i64 %h.w1, i64 %len17.64)
  %first.l = or i8 %first, 32
  %first.l.64 = zext i8 %first.l to i64
  %h.w3 = call i64 @int8pl(i64 %h.w2, i64 %first.l.64)
  %h.w4 = srem i64 %h.w3, 1000000007
  store i64 %h.w4, ptr %h
  store i32 0, ptr %tok.len
  store i32 0, ptr %tok.key
  br label %number.test

number.test:
  %in = load i1, ptr %innum
  br i1 %in, label %number, label %punct.test

number:
  %nnum.0 = load i32, ptr %nnum
  %nnum.1 = call i32 @int4pl(i32 %nnum.0, i32 1)
  store i32 %nnum.1, ptr %nnum
  %num.f = load i64, ptr %num
  %numsum.0 = load i64, ptr %numsum
  %numsum.1 = call i64 @int8pl(i64 %numsum.0, i64 %num.f)
  store i64 %numsum.1, ptr %numsum
  ; h := (h * 131 + num % 1000) % 1000000007
  %h.n0 = load i64, ptr %h
  %h.n1 = call i64 @int8mul(i64 %h.n0, i64 131)
  %num.m = srem i64 %num.f, 1000
  %h.n2 = call i64 @int8pl(i64 %h.n1, i64 %num.m)
  %h.n3 = srem i64 %h.n2, 1000000007
  store i64 %h.n3, ptr %h
  store i64 0, ptr %num
  store i1 false, ptr %innum
  br label %punct.test

punct.test:
  %is.space = icmp eq i8 %sc, 32
  br i1 %is.space, label %flushed, label %punct

punct:
  %npunct.0 = load i32, ptr %npunct
  %npunct.1 = call i32 @int4pl(i32 %npunct.0, i32 1)
  store i32 %npunct.1, ptr %npunct
  ; h := (h * 131 + ascii(c)) % 1000000007
  %h.p0 = load i64, ptr %h
  %h.p1 = call i64 @int8mul(i64 %h.p0, i64 131)
  %sc.64 = zext i8 %sc to i64
  %h.p2 = call i64 @int8pl(i64 %h.p1, i64 %sc.64)
  %h.p3 = srem i64 %h.p2, 1000000007
  store i64 %h.p3, ptr %h
  br label %flushed

flushed:
  br i1 %last, label %done, label %next

next:
  %pos.next = add nuw nsw i64 %pos, 1
  call void @plllvm_cfi()
  br label %scan

done:
  %nwords.r = load i32, ptr %nwords
  %ncap.r = load i32, ptr %ncap
  %nstop.r = load i32, ptr %nstop
  %nnum.r = load i32, ptr %nnum
  %numsum.r = load i64, ptr %numsum
  %npunct.r = load i32, ptr %npunct
  %longest.r = load i32, ptr %longest
  %h.r = load i64, ptr %h
  %b.1 = call ptr @put_i32(ptr %buf, i32 %nwords.r, i8 47)
  %b.2 = call ptr @put_i32(ptr %b.1, i32 %ncap.r, i8 47)
  %b.3 = call ptr @put_i32(ptr %b.2, i32 %nstop.r, i8 47)
  %b.4 = call ptr @put_i32(ptr %b.3, i32 %nnum.r, i8 47)
  %b.5 = call ptr @put_i64(ptr %b.4, i64 %numsum.r, i8 47)
  %b.6 = call ptr @put_i32(ptr %b.5, i32 %npunct.r, i8 47)
  %b.7 = call ptr @put_i32(ptr %b.6, i32 %longest.r, i8 47)
  call ptr @put_i64(ptr %b.7, i64 %h.r, i8 0)
  %r = call i64 @plllvm_cstring_to_text(ptr %buf)
  ret i64 %r

not_ascii:
  ; 0A000 = MAKE_SQLSTATE('0','A','0','0','0')
  call void @plllvm_error(i32 1088, ptr @msg.ascii)
  unreachable
}

; v in decimal at p, then sep; returns the byte after sep
define internal ptr @put_i32(ptr %p, i32 %v, i8 %sep) alwaysinline {
  %n = call i32 @pg_ltoa(i32 %v, ptr %p)
  %q = getelementptr inbounds i8, ptr %p, i32 %n
  store i8 %sep, ptr %q
  %r = getelementptr inbounds i8, ptr %q, i32 1
  ret ptr %r
}

define internal ptr @put_i64(ptr %p, i64 %v, i8 %sep) alwaysinline {
  %n = call i32 @pg_lltoa(i64 %v, ptr %p)
  %q = getelementptr inbounds i8, ptr %p, i32 %n
  store i8 %sep, ptr %q
  %r = getelementptr inbounds i8, ptr %q, i32 1
  ret ptr %r
}

; integer operators with PostgreSQL's "integer/bigint out of range" errors

define internal i32 @int4pl(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}

define internal i32 @int4mul(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.smul.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}

define internal i64 @int8pl(i64 %a, i64 %b) alwaysinline {
  %r = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %a, i64 %b)
  %ov = extractvalue { i64, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i64, i1 } %r, 0
  ret i64 %v
overflow:
  call void @plllvm_rt_bigint_overflow()
  unreachable
}

define internal i64 @int8mul(i64 %a, i64 %b) alwaysinline {
  %r = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %a, i64 %b)
  %ov = extractvalue { i64, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i64, i1 } %r, 0
  ret i64 %v
overflow:
  call void @plllvm_rt_bigint_overflow()
  unreachable
}
