#!/bin/sh

# We don't regenerate it on every "make" invocation - only by hand.
# The reason is that the changes to generated code are difficult
# to visualize by looking only at this script, it helps when the commit
# also contains the diff of the generated file.
exec >hash_md5_sha_x86-64.S

# Based on http://arctic.org/~dean/crypto/sha1.html.
# ("This SHA1 implementation is public domain.")
#
# x86-64 has at least SSE2 vector insns always available.
# We can use them without any CPUID checks (and without a need
# for a fallback code if needed insns are not available).
# This code uses them to calculate W[] ahead of time.
#
# Unfortunately, results are passed from vector unit to
# integer ALUs on the stack. MOVD/Q insns to move them directly
# from vector to integer registers are slower than store-to-load
# forwarding in LSU (on Skylake at least).
#
# The win against a purely integer code is small on Skylake,
# only about 7-8%. We offload about 1/3 of our operations to the vector unit.
# It can do 4 ops at once in one 128-bit register,
# but we have to use x2 of them because of W[0] complication,
# SSE2 has no "rotate each word by N bits" insns,
# moving data to/from vector unit is clunky, and Skylake
# has four integer ALUs unified with three vector ALUs,
# which makes pure integer code rather fast, and makes
# vector ops compete with integer ones.
#
# Zen3, with its separate vector ALUs, wins more, about 12%.

xmmT1="%xmm4"
xmmT2="%xmm5"
xmmRCONST="%xmm6"
xmmALLRCONST="%xmm7"
T=`printf '\t'`

# SSE instructions are longer than 4 bytes on average.
# Intel CPUs (up to Tiger Lake at least) can't decode
# more than 16 bytes of code in one cycle.
# By interleaving SSE code and integer code
# we mostly achieve a situation where 16-byte decode fetch window
# contains 4 (or more) insns.
#
# However. On Skylake, there was no observed difference,
# but on Zen3, non-interleaved code is ~3% faster
# (822 Mb/s versus 795 Mb/s hashing speed).
# Off for now:
interleave=false

INTERLEAVE() {
	$interleave || \
	{
		# Generate non-interleaved code
		# (it should work correctly too)
		echo "$1"
		echo "$2"
		return
	}
	(
	echo "$1" | grep -v '^$' >"$0.temp1"
	echo "$2" | grep -v '^$' >"$0.temp2"
	exec 3<"$0.temp1"
	exec 4<"$0.temp2"
	IFS=''
	while :; do
		line1=''
		line2=''
		while :; do
			read -r line1 <&3
			if test "${line1:0:1}" != "#" && test "${line1:0:2}" != "$T#"; then
				break
			fi
			echo "$line1"
		done
		while :; do
			read -r line2 <&4
			if test "${line2:0:4}" = "${T}lea"; then
				# We use 7-8 byte long forms of LEA.
				# Do not interleave them with SSE insns
				# which are also long.
				echo "$line2"
				read -r line2 <&4
				echo "$line2"
				continue
			fi
			if test "${line2:0:1}" != "#" && test "${line2:0:2}" != "$T#"; then
				break
			fi
			echo "$line2"
		done
		test "$line1$line2" || break
		echo "$line1"
		echo "$line2"
	done
	rm "$0.temp1" "$0.temp2"
	)
}

#	movaps  bswap32_mask(%rip), $xmmT1
# Load W[] to xmm0..3, byteswapping on the fly.
# For iterations 0..15, we pass RCONST+W[] in rsi,r8..r14
# for use in RD1As instead of spilling them to stack.
# (We use rsi instead of rN because this makes two
# ADDs in two first RD1As shorter by one byte).
#	movups	16*0(%rdi), %xmm0
#	pshufb	$xmmT1, %xmm0		#SSSE3 insn
#	movaps	%xmm0, $xmmT2
#	paddd	$xmmRCONST, $xmmT2
#	movq	$xmmT2, %rsi
#	#pextrq	\$1, $xmmT2, %r8        #SSE4.1 insn
#	#movhpd	$xmmT2, %r8             #can only move to mem, not to reg
#	shufps	\$0x0e, $xmmT2, $xmmT2	# have to use two-insn sequence
#	movq	$xmmT2, %r8		# instead
#	...
#	<repeat for xmm1,2,3>
#	...
#-	leal	$RCONST(%r$e,%rsi), %e$e	# e += RCONST + W[n]
#+	addl	%esi, %e$e			# e += RCONST + W[n]
# ^^^^^^^^^^^^^^^^^^^^^^^^
# The above is -97 bytes of code...
# ...but pshufb is a SSSE3 insn. Can't use it.

echo \
"### Generated by hash_md5_sha_x86-64.S.sh ###

#if CONFIG_SHA1_SMALL == 0 && defined(__GNUC__) && defined(__x86_64__)
	.section	.text.sha1_process_block64, \"ax\", @progbits
	.globl	sha1_process_block64
	.hidden	sha1_process_block64
	.type	sha1_process_block64, @function

	.balign	8	# allow decoders to fetch at least 5 first insns
sha1_process_block64:
	pushq	%rbp	# 1 byte insn
	pushq	%rbx	# 1 byte insn
#	pushq	%r15	# 2 byte insn
	pushq	%r14	# 2 byte insn
	pushq	%r13	# 2 byte insn
	pushq	%r12	# 2 byte insn
	pushq	%rdi	# we need ctx at the end

#Register and stack use:
# eax..edx: a..d
# ebp: e
# esi,edi,r8..r14: temps
# r15: unused
# xmm0..xmm3: W[]
# xmm4,xmm5: temps
# xmm6: current round constant
# xmm7: all round constants
# -64(%rsp): area for passing RCONST + W[] from vector to integer units

	movl	80(%rdi), %eax		# a = ctx->hash[0]
	movl	84(%rdi), %ebx		# b = ctx->hash[1]
	movl	88(%rdi), %ecx		# c = ctx->hash[2]
	movl	92(%rdi), %edx		# d = ctx->hash[3]
	movl	96(%rdi), %ebp		# e = ctx->hash[4]

	movaps	sha1const(%rip), $xmmALLRCONST
	pshufd	\$0x00, $xmmALLRCONST, $xmmRCONST

	# Load W[] to xmm0..3, byteswapping on the fly.
	#
	# For iterations 0..15, we pass W[] in rsi,r8..r14
	# for use in RD1As instead of spilling them to stack.
	# We lose parallelized addition of RCONST, but LEA
	# can do two additions at once, so it is probably a wash.
	# (We use rsi instead of rN because this makes two
	# LEAs in two first RD1As shorter by one byte).
	movq	4*0(%rdi), %rsi
	movq	4*2(%rdi), %r8
	bswapq	%rsi
	bswapq	%r8
	rolq	\$32, %rsi		# rsi = W[1]:W[0]
	rolq	\$32, %r8		# r8  = W[3]:W[2]
	movq	%rsi, %xmm0
	movq	%r8, $xmmT1
	punpcklqdq $xmmT1, %xmm0	# xmm0 = r8:rsi = (W[0],W[1],W[2],W[3])
#	movaps	%xmm0, $xmmT1		# add RCONST, spill to stack
#	paddd	$xmmRCONST, $xmmT1
#	movups	$xmmT1, -64+16*0(%rsp)

	movq	4*4(%rdi), %r9
	movq	4*6(%rdi), %r10
	bswapq	%r9
	bswapq	%r10
	rolq	\$32, %r9		# r9  = W[5]:W[4]
	rolq	\$32, %r10		# r10 = W[7]:W[6]
	movq	%r9, %xmm1
	movq	%r10, $xmmT1
	punpcklqdq $xmmT1, %xmm1	# xmm1 = r10:r9 = (W[4],W[5],W[6],W[7])

	movq	4*8(%rdi), %r11
	movq	4*10(%rdi), %r12
	bswapq	%r11
	bswapq	%r12
	rolq	\$32, %r11		# r11  = W[9]:W[8]
	rolq	\$32, %r12		# r12  = W[11]:W[10]
	movq	%r11, %xmm2
	movq	%r12, $xmmT1
	punpcklqdq $xmmT1, %xmm2	# xmm2 = r12:r11 = (W[8],W[9],W[10],W[11])

	movq	4*12(%rdi), %r13
	movq	4*14(%rdi), %r14
	bswapq	%r13
	bswapq	%r14
	rolq	\$32, %r13		# r13  = W[13]:W[12]
	rolq	\$32, %r14		# r14  = W[15]:W[14]
	movq	%r13, %xmm3
	movq	%r14, $xmmT1
	punpcklqdq $xmmT1, %xmm3	# xmm3 = r14:r13 = (W[12],W[13],W[14],W[15])
"

PREP() {
local xmmW0=$1
local xmmW4=$2
local xmmW8=$3
local xmmW12=$4
# the above must be %xmm0..3 in some permutation
local dstmem=$5
#W[0] = rol(W[13] ^ W[8]  ^ W[2] ^ W[0], 1);
#W[1] = rol(W[14] ^ W[9]  ^ W[3] ^ W[1], 1);
#W[2] = rol(W[15] ^ W[10] ^ W[4] ^ W[2], 1);
#W[3] = rol(  0   ^ W[11] ^ W[5] ^ W[3], 1);
#W[3] ^= rol(W[0], 1);
echo "# PREP $@
	movaps	$xmmW12, $xmmT1
	psrldq	\$4, $xmmT1	# rshift by 4 bytes: T1 = ([13],[14],[15],0)

#	pshufd	\$0x4e, $xmmW0, $xmmT2	# 01001110=2,3,0,1 shuffle, ([2],[3],x,x)
#	punpcklqdq $xmmW4, $xmmT2	# T2 = W4[0..63]:T2[0..63] = ([2],[3],[4],[5])
# same result as above, but shorter and faster:
# pshufd/shufps are subtly different: pshufd takes all dwords from source operand,
# shufps takes dwords 0,1 from *2nd* operand, and dwords 2,3 from 1st one!
	movaps	$xmmW0, $xmmT2
	shufps	\$0x4e, $xmmW4, $xmmT2	# 01001110=(T2.dw[2], T2.dw[3], W4.dw[0], W4.dw[1]) = ([2],[3],[4],[5])

	xorps	$xmmW8, $xmmW0	# ([8],[9],[10],[11]) ^ ([0],[1],[2],[3])
	xorps	$xmmT1, $xmmT2	# ([13],[14],[15],0) ^ ([2],[3],[4],[5])
	xorps	$xmmT2, $xmmW0	# ^
	# W0 = unrotated (W[0]..W[3]), still needs W[3] fixup
	movaps	$xmmW0, $xmmT2

	xorps	$xmmT1, $xmmT1	# rol(W0,1):
	pcmpgtd	$xmmW0, $xmmT1	#  ffffffff for elements <0 (ones with msb bit 1)
	paddd	$xmmW0, $xmmW0	#  shift left by 1
	psubd	$xmmT1, $xmmW0	#  add 1 to those who had msb bit 1
	# W0 = rotated (W[0]..W[3]), still needs W[3] fixup

	pslldq	\$12, $xmmT2	# lshift by 12 bytes: T2 = (0,0,0,unrotW[0])
	movaps	$xmmT2, $xmmT1
	pslld	\$2, $xmmT2
	psrld	\$30, $xmmT1
#	xorps	$xmmT1, $xmmT2	# rol((0,0,0,unrotW[0]),2)
	xorps	$xmmT1, $xmmW0	# same result, but does not depend on/does not modify T2

	xorps	$xmmT2, $xmmW0	# W0 = rol(W[0]..W[3],1) ^ (0,0,0,rol(unrotW[0],2))
"
#	movq	$xmmW0, %r8	# high latency (~6 cycles)
#	movaps	$xmmW0, $xmmT1
#	psrldq	\$8, $xmmT1	# rshift by 8 bytes: move upper 64 bits to lower
#	movq	$xmmT1, %r10	# high latency
#	movq	%r8, %r9
#	movq	%r10, %r11
#	shrq	\$32, %r9
#	shrq	\$32, %r11
# ^^^ slower than passing the results on stack (!!!)
echo "
	movaps	$xmmW0, $xmmT2
	paddd	$xmmRCONST, $xmmT2
	movups	$xmmT2, $dstmem
"
}

# It's possible to interleave integer insns in rounds to mostly eliminate
# dependency chains, but this likely to only help old Pentium-based
# CPUs (ones without OOO, which can only simultaneously execute a pair
# of _adjacent_ insns).
# Testing on old-ish Silvermont CPU (which has OOO window of only
# about ~8 insns) shows very small (~1%) speedup.

RD1A() {
local a=$1;local b=$2;local c=$3;local d=$4;local e=$5
local n=$(($6))
local n0=$(((n+0) & 15))
local rN=$((7+n0/2))
echo "
# $n
";test $n0 = 0 && echo "
	leal	$RCONST(%r$e,%rsi), %e$e # e += RCONST + W[n]
	shrq	\$32, %rsi
";test $n0 = 1 && echo "
	leal	$RCONST(%r$e,%rsi), %e$e # e += RCONST + W[n]
";test $n0 -ge 2 && test $((n0 & 1)) = 0 && echo "
	leal	$RCONST(%r$e,%r$rN), %e$e # e += RCONST + W[n]
	shrq	\$32, %r$rN
";test $n0 -ge 2 && test $((n0 & 1)) = 1 && echo "
	leal	$RCONST(%r$e,%r$rN), %e$e # e += RCONST + W[n]
";echo "
	movl	%e$c, %edi		# c
	xorl	%e$d, %edi		# ^d
	andl	%e$b, %edi		# &b
	xorl	%e$d, %edi		# (((c ^ d) & b) ^ d)
	addl	%edi, %e$e		# e += (((c ^ d) & b) ^ d)
	movl	%e$a, %edi		#
	roll	\$5, %edi		# rotl32(a,5)
	addl	%edi, %e$e		# e += rotl32(a,5)
	rorl	\$2, %e$b		# b = rotl32(b,30)
"
}
RD1B() {
local a=$1;local b=$2;local c=$3;local d=$4;local e=$5
local n=$(($6))
local n13=$(((n+13) & 15))
local n8=$(((n+8) & 15))
local n2=$(((n+2) & 15))
local n0=$(((n+0) & 15))
echo "
# $n
	movl	%e$c, %edi		# c
	xorl	%e$d, %edi		# ^d
	andl	%e$b, %edi		# &b
	xorl	%e$d, %edi		# (((c ^ d) & b) ^ d)
	addl	-64+4*$n0(%rsp), %e$e	# e += RCONST + W[n & 15]
	addl	%edi, %e$e		# e += (((c ^ d) & b) ^ d)
	movl	%e$a, %esi		#
	roll	\$5, %esi		# rotl32(a,5)
	addl	%esi, %e$e		# e += rotl32(a,5)
	rorl	\$2, %e$b		# b = rotl32(b,30)
"
}

RD2() {
local a=$1;local b=$2;local c=$3;local d=$4;local e=$5
local n=$(($6))
local n13=$(((n+13) & 15))
local n8=$(((n+8) & 15))
local n2=$(((n+2) & 15))
local n0=$(((n+0) & 15))
echo "
# $n
	movl	%e$c, %edi		# c
	xorl	%e$d, %edi		# ^d
	xorl	%e$b, %edi		# ^b
	addl	-64+4*$n0(%rsp), %e$e	# e += RCONST + W[n & 15]
	addl	%edi, %e$e		# e += (c ^ d ^ b)
	movl	%e$a, %esi		#
	roll	\$5, %esi		# rotl32(a,5)
	addl	%esi, %e$e		# e += rotl32(a,5)
	rorl	\$2, %e$b		# b = rotl32(b,30)
"
}

RD3() {
local a=$1;local b=$2;local c=$3;local d=$4;local e=$5
local n=$(($6))
local n13=$(((n+13) & 15))
local n8=$(((n+8) & 15))
local n2=$(((n+2) & 15))
local n0=$(((n+0) & 15))
echo "
# $n
	movl	%e$b, %edi		# di: b
	movl	%e$b, %esi		# si: b
	orl	%e$c, %edi		# di: b | c
	andl	%e$c, %esi		# si: b & c
	andl	%e$d, %edi		# di: (b | c) & d
	orl	%esi, %edi		# ((b | c) & d) | (b & c)
	addl	%edi, %e$e		# += ((b | c) & d) | (b & c)
	addl	-64+4*$n0(%rsp), %e$e	# e += RCONST + W[n & 15]
	movl	%e$a, %esi		#
	roll	\$5, %esi		# rotl32(a,5)
	addl	%esi, %e$e		# e += rotl32(a,5)
	rorl	\$2, %e$b		# b = rotl32(b,30)
"
}

{
# Round 1
RCONST=0x5A827999
RD1A ax bx cx dx bp  0; RD1A bp ax bx cx dx  1; RD1A dx bp ax bx cx  2; RD1A cx dx bp ax bx  3;
RD1A bx cx dx bp ax  4; RD1A ax bx cx dx bp  5; RD1A bp ax bx cx dx  6; RD1A dx bp ax bx cx  7;
a=`PREP %xmm0 %xmm1 %xmm2 %xmm3 "-64+16*0(%rsp)"`
b=`RD1A cx dx bp ax bx  8; RD1A bx cx dx bp ax  9; RD1A ax bx cx dx bp 10; RD1A bp ax bx cx dx 11;`
INTERLEAVE "$a" "$b"
a=`echo "	pshufd	\\$0x55, $xmmALLRCONST, $xmmRCONST"
   PREP %xmm1 %xmm2 %xmm3 %xmm0 "-64+16*1(%rsp)"`
b=`RD1A dx bp ax bx cx 12; RD1A cx dx bp ax bx 13; RD1A bx cx dx bp ax 14; RD1A ax bx cx dx bp 15;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm2 %xmm3 %xmm0 %xmm1 "-64+16*2(%rsp)"`
b=`RD1B bp ax bx cx dx 16; RD1B dx bp ax bx cx 17; RD1B cx dx bp ax bx 18; RD1B bx cx dx bp ax 19;`
INTERLEAVE "$a" "$b"

# Round 2
RCONST=0x6ED9EBA1
a=`PREP %xmm3 %xmm0 %xmm1 %xmm2 "-64+16*3(%rsp)"`
b=`RD2 ax bx cx dx bp 20; RD2 bp ax bx cx dx 21; RD2 dx bp ax bx cx 22; RD2 cx dx bp ax bx 23;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm0 %xmm1 %xmm2 %xmm3 "-64+16*0(%rsp)"`
b=`RD2 bx cx dx bp ax 24; RD2 ax bx cx dx bp 25; RD2 bp ax bx cx dx 26; RD2 dx bp ax bx cx 27;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm1 %xmm2 %xmm3 %xmm0 "-64+16*1(%rsp)"`
b=`RD2 cx dx bp ax bx 28; RD2 bx cx dx bp ax 29; RD2 ax bx cx dx bp 30; RD2 bp ax bx cx dx 31;`
INTERLEAVE "$a" "$b"
a=`echo "	pshufd	\\$0xaa, $xmmALLRCONST, $xmmRCONST"
   PREP %xmm2 %xmm3 %xmm0 %xmm1 "-64+16*2(%rsp)"`
b=`RD2 dx bp ax bx cx 32; RD2 cx dx bp ax bx 33; RD2 bx cx dx bp ax 34; RD2 ax bx cx dx bp 35;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm3 %xmm0 %xmm1 %xmm2 "-64+16*3(%rsp)"`
b=`RD2 bp ax bx cx dx 36; RD2 dx bp ax bx cx 37; RD2 cx dx bp ax bx 38; RD2 bx cx dx bp ax 39;`
INTERLEAVE "$a" "$b"

# Round 3
RCONST=0x8F1BBCDC
a=`PREP %xmm0 %xmm1 %xmm2 %xmm3 "-64+16*0(%rsp)"`
b=`RD3 ax bx cx dx bp 40; RD3 bp ax bx cx dx 41; RD3 dx bp ax bx cx 42; RD3 cx dx bp ax bx 43;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm1 %xmm2 %xmm3 %xmm0 "-64+16*1(%rsp)"`
b=`RD3 bx cx dx bp ax 44; RD3 ax bx cx dx bp 45; RD3 bp ax bx cx dx 46; RD3 dx bp ax bx cx 47;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm2 %xmm3 %xmm0 %xmm1 "-64+16*2(%rsp)"`
b=`RD3 cx dx bp ax bx 48; RD3 bx cx dx bp ax 49; RD3 ax bx cx dx bp 50; RD3 bp ax bx cx dx 51;`
INTERLEAVE "$a" "$b"
a=`echo "	pshufd	\\$0xff, $xmmALLRCONST, $xmmRCONST"
   PREP %xmm3 %xmm0 %xmm1 %xmm2 "-64+16*3(%rsp)"`
b=`RD3 dx bp ax bx cx 52; RD3 cx dx bp ax bx 53; RD3 bx cx dx bp ax 54; RD3 ax bx cx dx bp 55;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm0 %xmm1 %xmm2 %xmm3 "-64+16*0(%rsp)"`
b=`RD3 bp ax bx cx dx 56; RD3 dx bp ax bx cx 57; RD3 cx dx bp ax bx 58; RD3 bx cx dx bp ax 59;`
INTERLEAVE "$a" "$b"

# Round 4 has the same logic as round 2, only n and RCONST are different
RCONST=0xCA62C1D6
a=`PREP %xmm1 %xmm2 %xmm3 %xmm0 "-64+16*1(%rsp)"`
b=`RD2 ax bx cx dx bp 60; RD2 bp ax bx cx dx 61; RD2 dx bp ax bx cx 62; RD2 cx dx bp ax bx 63;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm2 %xmm3 %xmm0 %xmm1 "-64+16*2(%rsp)"`
b=`RD2 bx cx dx bp ax 64; RD2 ax bx cx dx bp 65; RD2 bp ax bx cx dx 66; RD2 dx bp ax bx cx 67;`
INTERLEAVE "$a" "$b"
a=`PREP %xmm3 %xmm0 %xmm1 %xmm2 "-64+16*3(%rsp)"`
b=`RD2 cx dx bp ax bx 68; RD2 bx cx dx bp ax 69; RD2 ax bx cx dx bp 70; RD2 bp ax bx cx dx 71;`
INTERLEAVE "$a" "$b"
RD2 dx bp ax bx cx 72; RD2 cx dx bp ax bx 73; RD2 bx cx dx bp ax 74; RD2 ax bx cx dx bp 75;
RD2 bp ax bx cx dx 76; RD2 dx bp ax bx cx 77; RD2 cx dx bp ax bx 78; RD2 bx cx dx bp ax 79;
} | grep -v '^$'

echo "
	popq	%rdi		#
	popq	%r12		#
	addl	%eax, 80(%rdi)	# ctx->hash[0] += a
	popq	%r13		#
	addl	%ebx, 84(%rdi)	# ctx->hash[1] += b
	popq	%r14		#
	addl	%ecx, 88(%rdi)	# ctx->hash[2] += c
#	popq	%r15		#
	addl	%edx, 92(%rdi)	# ctx->hash[3] += d
	popq	%rbx		#
	addl	%ebp, 96(%rdi)	# ctx->hash[4] += e
	popq	%rbp		#

	ret
	.size	sha1_process_block64, .-sha1_process_block64

	.section	.rodata.cst16.sha1const, \"aM\", @progbits, 16
	.balign	16
sha1const:
	.long	0x5A827999
	.long	0x6ED9EBA1
	.long	0x8F1BBCDC
	.long	0xCA62C1D6

#endif"
