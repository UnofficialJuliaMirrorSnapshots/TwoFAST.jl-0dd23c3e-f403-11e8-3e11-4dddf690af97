module TwoFAST

export xicalc
export F21EllCache, make_fell_lmax_cache
export MlCache, calcMljj
export calcwljj


# from this package
include("PerformanceStats.jl")
include("Miller.jl")
using .PerformanceStats
using .Miller

# other packages
using FFTW
using IncGammaBeta
using LinearAlgebra
using SpecialFunctions
using DelimitedFiles
using Logging
#using SphBes

import Base.write


# Nemo
module NemoHyp2F1
export hyp2f1
using Nemo
CC = ComplexField(1024)
toacb(x) = CC(real(x), imag(x))
function hyp2f1(a::Number, b::Number, c::Number, z::Number)
    #@show toacb(a) toacb(b) toacb(c) toacb(z)
    res = Nemo.hyp2f1(toacb(a), toacb(b), toacb(c), toacb(z))
    #@show res
    return ComplexF64(Float64(real(res)), Float64(imag(res)))
end
end
using .NemoHyp2F1



###################### muladd variants ##############################

function muladd_a_b!(dest, b, scalar, src, a)
	@assert size(src,1) == size(dest,1)
	@assert size(src,2) == size(dest,2)
	@assert 1 <= b <= size(dest,3)
	@assert 1 <= a <= size(src,3)
	for j=1:size(src,2), i=1:size(src,1)
		@inbounds dest[i,j,b] += scalar * src[i,j,a]
	end
end

function muladdset_a_b!(dest, b, scalar, src, a)
	@assert size(src,1) == size(dest,1)
	@assert size(src,2) == size(dest,2)
	@assert 1 <= b <= size(dest,3)
	@assert 1 <= a <= size(src,3)
	for j=1:size(src,2), i=1:size(src,1)
		@inbounds dest[i,j,b] = scalar * src[i,j,a]
	end
end


############ phi(), Fourier transform window functions ###########

function windowfn(x::Number, xmin, xleft, xright, xmax)
	@assert xmin < xleft < xright < xmax
	if x > xleft && x < xright
		return 1.0
	elseif x < xmin || x > xmax
		return 0.0
	elseif x < xleft
		r = (x - xmin) / (xleft - xmin)
	elseif x > xright
		r = (xmax - x) / (xmax - xright)
	end
	return r - sinpi(2*r)/(2*pi)
end
function windowfn(x; dlnxleft=0.46, dlnxright=0.46)
	xmin = minimum(x)
	xleft = exp(log(xmin) + dlnxleft)
	xmax = maximum(x)
	xright = exp(log(xmax) - dlnxright)
	windowfn.(x, xmin, xleft, xright, xmax)
end

one(x) = ones(length(x))


function make_phi(pkfn, k0, N, L, q, winx, wink)
	k = @. k0 * exp((0:N-1) * (2 * pi / L))
	pk = pkfn.(k)
	return make_phi((k, pk), k0, N, L, q, winx, wink)
end

function make_phi(pkfn::Tuple, k0, N, L, q, winx, wink)
	k = pkfn[1]
	pk = pkfn[2]
	kpk = (@. (k/k0)^(3 - q) * pk) .* winx(k)
	phi = conj(rfft(kpk)) / L
	phi .*= wink(k)[length(k)-length(phi)+1:end]
	return phi
end


######################## xicalc() ############################

function make_Mellnu(tt, alpha, ell, nu; q=0)
	n = @. q - nu - 1 - im*tt
	intjlttn = @. 2.0^(n-1) * sqrt(pi) * exp(loggamma((1 + ell + n) / 2)
		- loggamma((2 + ell - n) / 2))
	A = @. alpha^(im*tt - q + nu)
	#println("n: $(n[1])")
	#println("intjlttn: $(intjlttn[1])")
	#println("A: $(A[1])")
	return A .* intjlttn
end


function calc_qbest(ell, nu; n1=0.9, n2=0.9999)
	qbest = (2 + n1 + n2) / 2 - nu
        #qbest = 2.0 - nu
        qmin = max(n2 - 1.0 - nu, -ell)
        qmax = min(n1 + 3.0 - nu, 2.0)

	q = qbest
	if !(qmin < q < qmax)
		#@warn "Need suboptimal choice of q!" qmin qmax qbest
        	q = (qmin + 2qmax) / 3
	end

        #q = (qmin + 2qmax) / 3

	#q = (qbest < qmin) ? qmin : (qbest > qmax ? qmax : qbest)

	return q, qbest, qmin, qmax
end


function xicalc(pkfn::T, ell=0, nu=0; kmin=1e-4, kmax=1e4, r0=1e-4, N=1000,
		q::Tq=:auto, winx=windowfn, wink=windowfn,
		) where {T,Tq}
	if T <: Tuple
		kmin = minimum(pkfn[1])
		kmax = maximum(pkfn[1]) * pkfn[1][2] / pkfn[1][1]
		N = length(pkfn[1])
	end

	if Tq <: Number
		qnu = q
	else
		qnu, qbest, qmin, qmax = calc_qbest(ell, nu)
		#println()
		#println("  qbest: $qbest")
		#println("  qmin:  $qmin")
		#println("  qmax:  $qmax")
		#println("  (ell,nu) = ($ell,$nu), qnu=$qnu")
		if qmin > qmax
		    @error "Integral does not converge!" qmin qmax qbest qnu
		    @assert false
		end
	end

	N2 = div(N,2) + 1
	k0 = kmin
	G = log(kmax / kmin)
	alpha = k0 * r0

	L = 2 * pi * N / G

	tt = (2 * pi / G) * (0:N2-1)

	rr = @. r0 * exp((0:N-1) * (G / N))

	prefac = @. (k0^3 / (pi * alpha^nu * G)) * (rr / r0)^(-(qnu+nu))

	Mellnu = make_Mellnu(tt, alpha, ell, 0; q=qnu)

	phi = make_phi(pkfn, k0, N, L, qnu + nu, winx, wink)

	#println(N)
	#println(typeof(pkfn))
	#println(length(phi))
	#println(all(isfinite.(phi)))
	#println(length(Mellnu))
	#println(all(isfinite.(Mellnu)))
	#println(length(prefac))
	#println(all(isfinite.(prefac)))
	xi = prefac .* brfft(phi .* Mellnu, N)

	return rr, xi
end


########################### (l,l') -> (j,j') #############################

function wljj_from_wldl!(wtRdllm2::Array{Complex{Float64},3},
			 wtRdll0::Array{Complex{Float64},3},
			 wtRdllp2::Array{Complex{Float64},3},
			 L::Int64,
			 wjj::Array{Complex{Float64},3})
	f1 = L * (L - 1) / ((2L - 1) * (2L + 1))
	f2 = -(2L^2 + 2L - 1) / ((2L - 1) * (2L + 3))
	f3 = (L + 1) * (L + 2) / ((2L + 1) * (2L + 3))

	m2m2 = 3
	m2e0 = 4
	m2p2 = 5
	e0m2 = 2
	e0e0 = 3
	e0p2 = 4
	p2m2 = 1
	p2e0 = 2
	p2p2 = 3

	muladdset_a_b!(wjj, 1, 1, wtRdll0, e0e0)

	muladdset_a_b!(wjj, 2, f1, wtRdll0, e0m2)
	muladd_a_b!(wjj, 2, f2, wtRdll0, e0e0)
	muladd_a_b!(wjj, 2, f3, wtRdll0, e0p2)

	muladdset_a_b!(wjj, 3, f1, wtRdllm2, m2e0)
	muladd_a_b!(wjj, 3, f2, wtRdll0,  e0e0)
	muladd_a_b!(wjj, 3, f3, wtRdllp2, p2e0)

	muladdset_a_b!(wjj, 4, f1 * f1, wtRdllm2, m2m2)
	muladd_a_b!(wjj, 4, f2 * f1, wtRdll0,  e0m2)
	muladd_a_b!(wjj, 4, f3 * f1, wtRdllp2, p2m2)
	muladd_a_b!(wjj, 4, f1 * f2, wtRdllm2, m2e0)
	muladd_a_b!(wjj, 4, f2 * f2, wtRdll0,  e0e0)
	muladd_a_b!(wjj, 4, f3 * f2, wtRdllp2, p2e0)
	muladd_a_b!(wjj, 4, f1 * f3, wtRdllm2, m2p2)
	muladd_a_b!(wjj, 4, f2 * f3, wtRdll0,  e0p2)
	muladd_a_b!(wjj, 4, f3 * f3, wtRdllp2, p2p2)
end

function wljj_dl(ell, j1, j2, wldl; abs_coeff=false)
	@assert j1 == 0 || j1 == 2
	@assert j2 == 0 || j2 == 2
	f0 = ell * (ell - 1) / ((2 * ell - 1) * (2 * ell + 1))
	f1 = - (2 * ell^2 + 2 * ell - 1) / ((2 * ell - 1) * (2 * ell + 3))
	f2 = (ell + 1) * (ell + 2) / ((2 * ell + 1) * (2 * ell + 3))
	if abs_coeff
		f0 = abs(f0)
		f1 = abs(f1)
		f2 = abs(f2)
	end
	if j1 == 0 && j2 == 0
		w = wldl[0,0]
	elseif j1 == 0 && j2 == 2
		w0 = wldl[0,-2]
		w1 = wldl[0, 0]
		w2 = wldl[0,+2]
		w = f0 * w0 + f1 * w1 + f2 * w2
	elseif j1 == 2 && j2 == 0
		w0 = wldl[-2,0]
		w1 = wldl[ 0,0]
		w2 = wldl[+2,0]
		w = f0 * w0 + f1 * w1 + f2 * w2
	else # j1 == 2 && j2 == 2
		w00 = wldl[-2,-2]
		w01 = wldl[-2, 0]
		w02 = wldl[-2,+2]
		w10 = wldl[ 0,-2]
		w11 = wldl[ 0, 0]
		w12 = wldl[ 0,+2]
		w20 = wldl[+2,-2]
		w21 = wldl[+2, 0]
		w22 = wldl[+2,+2]
		w = ( f0*f0*w00 + f0*f1*w01 + f0*f2*w02
		+ f1*f0*w10 + f1*f1*w11 + f1*f2*w12
		+ f2*f0*w20 + f2*f1*w21 + f2*f2*w22 )
	end
	w
end


################### 2F1 functions #########################
# Use Miller's algorithm
function calc_f000_fm1m1m2_ell0_dl0m1(R::T, n::Complex{T}, dl::Integer) where T
	if dl == 0
		f000fna(m) = 1/(2m*R) * ((1+R)^m - (1-R)^m)
		fm1m1m2fna(m) = 1/2 * ((1 - m*R)*(1+R)^m + (1 + m*R)*(1-R)^m)
		f000 = f000fna(1-n)
		fm1m1m2 = fm1m1m2fna(1-n)
	elseif dl == -1
		f000fnb(m) = 1/2 * ((1+R)^m + (1-R)^m)
		fm1m1m2fnb(m) = 1/6 * ((3 - 3m*R - (1-m^2)*R^2)*(1+R)^m
				  + (3 + 3m*R - (1-m^2)*R^2)*(1-R)^m)
		f000 = f000fnb(1-n)
		fm1m1m2 = fm1m1m2fnb(1-n)
	else
		@error "dl=$dl not implemented" R n
		@assert false
	end
	return [fm1m1m2, f000]
end

function BCDEfn_dl(R::T, n::Complex{T}, dl::Integer) where T
	# Our implementation of Miller's alg gives us where we want to go, not
	# where we start:
	dl = dl + 2
	ell = 0
	a = 0.5n + 0.5dl
	b = ell + 0.5 + a
	c = ell + 1.5 + dl
	z = R^2
	B = 1 - (a * (c-b) + b * (c-a) - 3c + 4) / ((c-2) * (c-4)) * z
	C = -(c-1-a) * z * (c-1-b) * z * (a-1) * (b-1) / ((c-1) * (c-2)^2 * (c-3))
	D = Complex{T}(1)
	E = Complex{T}(0)
	return B, C, D, E
end

function calc_f000_f0m10_ell0(R::T, n::Complex{T}, dl::Integer) where T
	f0 = calc_f000_fm1m1m2_ell0_dl0m1(R, n, isodd(dl) ? -1 : 0)
	z = R^2
	fasymp = [Complex{T}((1-z/2)/2 + sqrt(1-z)/2), Complex{T}(1)]
	laminf1 = ((1 - z / 2) - sqrt(1 - z)) / 2
	laminf2 = ((1 - z / 2) + sqrt(1 - z)) / 2
	BCfn(dl2) = BCDEfn_dl(R, n, 2dl2)
	dl2max = ceil(Int, dl/2 - 1/4)  # the 1/4 combats round-off
	fn, nmax = miller(dl2max, BCfn, f0, fasymp, laminf1, laminf2, fmax_tol=1e-13)
	fm1m1m2, f000 = fn
	@assert nmax == dl2max
	ell = 0
	a = 0.5n + 0.5dl
	b = ell + 0.5 + a
	c = ell + 1.5 + dl
	oobomz = 1 / (b * (1-z))
	f010 = ((c-1) * oobomz * fm1m1m2
		+ ((2b - c + (a-b) * z) * oobomz
		   - (c - 2 - (c-1-a) * z) * oobomz * (b-1) / (c-2)) * f000)
	return [f000, f010]
end


function calc_f0(R::T, n::Complex{T}, dl::Integer; use_arb=false) where T
	if n + dl == 0
		return [Complex{T}(1), Complex{T}(1)]
	end
	fn = calc_f000_f0m10_ell0(R, n, dl)
	#println("fn: $fn")
	return fn
end


function calc_Mll_unity(ell, n::Complex{T}, dl, alpha) where T
	if n + dl == 0
		return [Complex{T}(1), Complex{T}(1)]
	end
	# Here we assume R=1
	ell1 = ell
	ell2 = ell + dl
	a = n/2 + dl/2
	b = ell + T(1)/2 + a
	c = ell + dl + T(3)/2
	# gamma(c) was cancelled
	lngr = loggamma(b) - loggamma(1-a) - loggamma(c-a)
	Uellell_pre = T(2)^(n-2) * pi
	val_pre = alpha^(-n-1) * Uellell_pre
	f000 = exp(loggamma(c-a-b) - loggamma(c-b) + lngr) * val_pre
	f010 = Complex{T}(0)  # when R=1, then f010 does not enter the recursion relations
        #println("  a: $a")
        #println("  b: $b")
        #println("  c: $c")
        #println("  lngr: $lngr")
        #println("  Uellell_pre: $Uellell_pre")
        #println("  val_pre: $val_pre")
        #println("  f000: $f000")
        #println("  f010: $f010")
	return [f000, f010]
end


function BCDEfn(ell, dl, a, R)
	c = ell + dl + 3/2
	ainvc = a / c
	dloc = dl / c
	b = c + a - 1 - dl
	z = R^2
	fac = c / (R * b)

	B = fac * (z - ainvc + dloc * (1 - z))
	C = fac * (1 + ainvc - dloc) * (1 - z)
	D = fac * (-ainvc + dloc)
	E = fac * (1 + ainvc - dloc)

	return B, C, D, E
end


function calc_2f1_RqmG(ell, R::T, dl::Integer; q=1.0, m::Int=500,
		       G=log(1e4/1e-4), alpha=1e-4,
		       allow_nemo=true) where {T<:Real}
	t = 2 * T(pi) * m / G
	n = q - 1 - im * t
	a = n / 2 + dl / 2
	BCfn(ell) = BCDEfn(ell, dl, a, R)
	fnull = [Complex{T}(0), Complex{T}(0)]

	@assert R <= 1

	if R == 0 && ell+dl != 0
		return fnull, ell
	elseif R == 1
		#@show "R=1!"
		calc_fmax_unity(ell) = calc_Mll_unity(ell, n, dl, alpha)
		fell = calc_fmax_unity(ell)
		if !all(isfinite.(fell)) || norm(fell) < Miller.floatmin(fell)
			fell, ell = Miller.calc_underflow_fmax(ell, calc_fmax_unity)
		end
	elseif allow_nemo && R > 0.99
		#@show "nemo!"
		b = ell + 0.5 + a
		c = ell + 1.5 + dl
		z = R^2
		Aelldl = alpha^(t*im-q) * 2^(n-2) * pi
		Aelldl *= exp((ell+dl)*log(R) + loggamma(b) - loggamma(1-a)
			      - loggamma(c))
		f000 = hyp2f1(a, b, c, z)
		f010 = hyp2f1(a, b+1, c, z)
		m000 = Aelldl * f000
		m010 = Aelldl * f010
		fell = [m000, m010]
		if !all(isfinite.(fell))
			@error "Mll could not be calculated using Nemo" R n q t ell dl alpha Aelldl a b c z f000 f010 m000 m010
			@assert false
		end
		@assert norm(fell) != 0  # since we don't try to find lmax
	else
		#@show "miller!"
		B0 = Mellell_pre(0, 0+dl, R, n, alpha)
		f21 = calc_f0(R, n, dl)
		f0 = B0 * f21
		if !all(isfinite.(f0)) && n != 0 && R != 1
			@error "Matchpoint could not be calculated" R n dl alpha B0 f21 f0
			@assert false
		end
		laminf1 = R
		laminf2 = 1 / R
		fasymp = [Complex{T}(1), Complex{T}(1)]
		#println("R: $R")
		#println("n: $n")
		#println("dl: $dl")
		#println("alpha: $alpha")
		#println("f0:     $f0")
		#println("laminf1: $laminf1")
		#println("laminf2: $laminf2")
		fell, ell = miller(ell, BCfn, f0, fasymp, laminf1, laminf2)
		if !all(isfinite.(fell))
			@error "Mll could not be calculated" R n dl alpha B0 f21 f0 fell ell
			@assert false
		end
	end

	#println("fell: $fell")
	#println("ell: $ell")
	return fell, ell
end


#################### b+1 recursion ###########################

function stepfor_2f1!(mm, RR, ell, Am, hypAB)
	# update from ell -> ell+1
	# b+1 relation
	c = ell + 3 / 2
	for j=1:length(RR)
		z = RR[j]^2
		omz = 1 - z
		for i=1:length(mm)
			a = Am[i]
			bp1 = c + a
			F000 = hypAB[1,i,j]
			F010 = hypAB[2,i,j]
			F011 = c * (F000 - omz * F010) / ((c-a) * z)
			F021 = (c * F010 + a * F011) / bp1
			hypAB[1,i,j] = F011
			hypAB[2,i,j] = F021
		end
	end
end


function stepback!(RR, ell, Am, dlrec, hypAB, lmax)
	# update ell -> ell-1, using b+1 relation, including prefactor
        c = ell + dlrec + 1/2  # Eqs B10-B11 do ell+1->ell, hence c = (ell-1) + 3/2
        cinv = 1 / c
	for j=1:length(RR)
		R = RR[j]
                if R > 1  # R>1 has its own function
                    continue
                end
		z = R^2
		omz = 1 - z
		cinvz = cinv * z
		coR = c / R
		for i=1:length(Am)
			if ell > lmax[i,j]
				continue
			end
			a = Am[i] + dlrec/2
			F011 = hypAB[1,i,j]
			F021 = hypAB[2,i,j]
			if F011 == 0 && F021 == 0
				continue
			end
			if a == 0 && F011 == 1.0 && F021 == 1.0
				continue
			end
			bp1 = c + a - dlrec
			cma = c - a
			b = bp1 - 1
                        cmbm1 = dlrec - a
			coRb = coR / b
			F010 = cinv * (bp1 * F021 + cmbm1 * F011)
			F000 = cinvz * cma * F011 + omz * F010
			hypAB[1,i,j] = coRb * F000
			hypAB[2,i,j] = coRb * F010
			if !isfinite(F000) || !isfinite(F010)
				@error "Hypergeometric functions could not be calculated!" ell i,j F011,F021 F000,F010 RR[j] dlrec a b c
				@assert false
			end
		end
	end
end


function stepbackRg1!(RR, ell, Am, dlrec, hypAB, lmax)
	# update ell -> ell-1, using b+1 relation, including prefactor
        c = ell + 1/2  # Eqs B10-B11 do ell+1->ell, hence c = (ell-1) + 3/2
        cinv = 1 / c
	for j=1:length(RR)
                if RR[j] <= 1  # R<1 has its own function
                    continue
                end
		R = 1/RR[j]
		z = R^2
		omz = 1 - z
		cinvz = cinv * z
		coR = c / R
		for i=1:length(Am)
			if ell > lmax[i,j]
				continue
			end
			a = Am[i] - dlrec/2
			F011 = hypAB[1,i,j]
			F021 = hypAB[2,i,j]
			if F011 == 0 && F021 == 0
				continue
			end
			if a == 0 && F011 == 1.0 && F021 == 1.0
				continue
			end
			bp1 = c + a + dlrec
			cma = c - a
			b = bp1 - 1
                        cmbm1 = - (a + dlrec)
			coRb = coR / b
			F010 = cinv * (bp1 * F021 + cmbm1 * F011)
			F000 = cinvz * cma * F011 + omz * F010
			hypAB[1,i,j] = coRb * F000
			hypAB[2,i,j] = coRb * F010
			if !isfinite(F000) || !isfinite(F010)
				@error "Hypergeometric functions could not be calculated!" ell i,j F011,F021 F000,F010 RR[j] dlrec a b c
				@assert false
			end
		end
	end
end


############## Mellell utilities #############################

function Mellell_pre(ell1, ell2, R::T, n, alpha::T) where T
	#a = (ell2 - ell1 + n) / 2
	b = (1 + ell1 + ell2 + n) / 2
	c = ell2 + T(3) / 2
	d = (2 + ell1 - ell2 - n) / 2
	gr = exp(ell2 * log(R) + loggamma(b) - loggamma(d) - loggamma(c))
	Uellell_pre = T(2)^(n-2) * pi * gr
	val_pre = alpha^(-n-1) * Uellell_pre
	#println("ell1=$ell1, ell2=$ell2, t=$t, R=$R, alpha=$alpha, q=$q")
	#println("n=$n, b=$b, c=$c, d=$d, gr=$gr, U=$Uellell_pre, pre=$val_pre")
	return val_pre
end


function calc_Mellell_lmax!(ell, fell, flmax, Mellell, Mellbp1)
	# TODO: Since we don't overwrite Mell and Mellbp1 anywhere else, we
	# should be able to skip this step, and use 'fell' directly. However,
	# underflow ('flmax') complicates this, so let's keep this step for
	# now.
	@assert size(fell,1) == 2
	@assert size(fell,2) ==
		size(flmax,1) ==
		size(Mellell,1) ==
		size(Mellbp1,1)
	@assert size(fell,3) ==
		size(flmax,2) ==
		size(Mellell,2) ==
		size(Mellbp1,2)
	@inbounds for j=1:size(Mellell,2), i=1:size(Mellell,1)
		if ell > flmax[i,j]
			Mellell[i,j] = 0.0
			Mellbp1[i,j] = 0.0
		else
			Mellell[i,j] = fell[1,i,j]
			Mellbp1[i,j] = fell[2,i,j]
		end
		if !isfinite(Mellell[i,j]) || !isfinite(Mellbp1[i,j])
			@error "Mellell could not be calculated!" ell i,j flmax[i,j] fell[1,i,j] fell[2,i,j] Mellell[i,j] Mellbp1[i,j]
			@assert false
		end
	end
end


########################## dl ± 2 recursions ###################
t0 = @timed Nothing
tm2 = @timed Nothing
tm2s = @timed Nothing
tm4 = @timed Nothing
tp2 = @timed Nothing
tp2s = @timed Nothing
tp4 = @timed Nothing

function copy_ixy_i!(D, j, k, S)
	@assert size(D,1) == length(S)
	@assert size(D,2) >= j >= 1
	@assert size(D,3) >= k >= 1
	for i=1:length(S)
		@inbounds D[i,j,k] = S[i]
	end
end

function copy_ixy_ix!(D, j, k, S)
	@assert size(D,1) == size(S,1)
	@assert size(D,2) >= j >= 1
	@assert size(S,2) >= j >= 1
	@assert size(D,3) >= k >= 1
	for i=1:size(S,1)
		@inbounds D[i,j,k] = S[i,j]
	end
end

function copy_ij_ijxy!(D, S, k, l)
	@assert size(D,1) == size(S,1)
	@assert size(D,2) == size(S,2)
	@assert size(S,3) >= k >= 1
	@assert size(S,4) >= l >= 1
	for j=1:size(D,2), i=1:size(D,1)
		@inbounds D[i,j] = S[i,j,k,l]
	end
end

function rec_m2!(c, z, Am0, dlrec, Mell, Mellbp1, idx, work1, work2)
	# initial dl=-2 recursion:
	#println("c=$c, Am0=$Am0")
	omz = 1 - z
	cm1 = c - 1
	cm2 = c - 2
	cm2cm1 = cm2 * cm1
	amb = dlrec - cm1
	for i=1:length(Am0)
		a = Am0[i] + dlrec/2
		b = c + a - 1 - dlrec
		bm1 = b - 1
		F000 = Mell[i,idx]
		F010 = Mellbp1[i,idx]
		if F000 == 0 && F010 == 0
			work1[i] = F000
			work2[i] = F010
			continue
		end
		oma = 1 - a
		cmb = dlrec + oma
		twobmc = c-2cmb
		F0m10 = (b * omz * F010 - (twobmc+amb*z) * F000) / cmb
                #println("a=$a, b=$b, c=$c")
                #println("F0m10: $F0m10")
		denominator = 1 / (bm1 * oma * z)
		cm2mR2cm1ma = cm2 - z * (cm1 - a)
		work1[i] = (cm2 * cmb * F0m10 + cm2mR2cm1ma * bm1 * F000) * denominator
		work2[i] = F000 * cm2cm1 * denominator
	end
end

function rec_m4!(C0, z, Am0, dlrec, wtdl, idx, Nell2, work1, work2)
	# towards dl=-4:
	#println("C0=$C0, Am0=$Am0")
	for j=-2:-1:-Nell2
		dl2 = j + 2  # we use a, b, c as they are for F[0,0,0]
		c = C0 + 2*dl2
		cm1 = c - 1
		cm2 = c - 2
		cm3 = c - 3
		cm4 = c - 4
		c3m4 = 3 * c - 4
		cm2cm4 = cm2 * cm4
		f2inv = 1 / cm2cm4
		f4inv = 1 / (cm1 * cm2^2 * cm3)
		cm4cm3 = cm4 * cm3
		for i=1:length(Am0)
			Fm1m1m2 = work1[i]
			F000 = work2[i]
			if Fm1m1m2 == 0 && F000 == 0
				continue
			end
			a = Am0[i] + dlrec/2 + dl2
			b = c - 1 - dlrec - 2dl2 + a
			am1 = a - 1
			bm1 = b - 1
			cma = c - a
			cmb = c - b
			cm1maz = (cma - 1) * z
			cm1mbz = (cmb - 1) * z
			f1 = cm2cm4 - (a * cmb + b * cma - c3m4) * z
			f3 = cm1maz * cm1mbz * am1 * bm1
			Aellratio = cm4cm3 / ((bm1-1) * (2 - a) * z)
			work1[i] = Aellratio * (f1 * f2inv * Fm1m1m2 - f3 * f4inv * F000)
			work2[i] = Aellratio * Fm1m1m2
		end
		#wtdl[:,idx,Nell2+j+1] .= work1
		copy_ixy_i!(wtdl, idx, Nell2+j+1, work1)
	end
end

function rec_p2!(c, z, Am0, dlrec, Mell, Mellbp1, idx, work1, work2)
	# initial dl=2 recursion:
	zoccp1 = z / (c * (c + 1))
	ooz = 1 / z
	omz = 1 - z
	amb = 1 - c + dlrec
	for i=1:length(Am0)
		a = Am0[i] + dlrec/2
		b = c + a - 1 - dlrec
		F000 = Mell[i,idx]
		F010 = Mellbp1[i,idx]
		cmb = 1 + dlrec - a
		twobmc = c-2cmb
		F0m10 = (b * omz * F010 - (twobmc+amb*z) * F000) / cmb
		work1[i] = ooz * (c * F0m10 - (c - a * z) * F000) / (c - a)
		work2[i] = - F000 * a * b * zoccp1
	end
end

function rec_p4!(C0, z, Am0, dlrec, wtdl, idx, Nell2, M2, work1, work2)
	# towards dl=4:
	for j=2:M2
		dl2 = j - 2
		dl = 2 * dl2
		c = C0 + dl
		cp1 = c + 1
		cp2 = c + 2
		cp3 = c + 3
		cp2c = cp2 * c
		c3p8 = 3 * c + 8
		R2ocp2cp3 = z / (cp2 * cp3)
		for i=1:length(Am0)
			F112 = work1[i]
			F000 = work2[i]
			if F112 == 0 && F000 == 0
				continue
			end
			a = Am0[i] + dlrec/2 + dl2
			b = c - 1 + a - dlrec - dl
			ccp1mazcp1mbz = c * (cp1-a) * z * (cp1-b) * z
			ap2cp2mb = (a + 2) * (cp2 - b)
			bp2cp2ma = (b + 2) * (cp2 - a)
			fac = - z * cp1 / ccp1mazcp1mbz
			work1[i] = fac * ((cp2c - (ap2cp2mb + bp2cp2ma - c3p8) * z) * F112
				- cp2c * F000)
			work2[i] = - (a+1) * (b+1) * R2ocp2cp3 * F112
		end
		#wtdl[:,idx,Nell2+j+1] .= work1
		copy_ixy_i!(wtdl, idx, Nell2+j+1, work1)
	end
end

function compute_wl!(wtdl, idx, Am0, C0, dlrec, R, Mell, Mellbp1, work1, work2, dlmin, dlmax)
        c = C0 + dlrec
	z = R^2
	Nell2 = max(0, div(dlrec - dlmin, 2))
        #println("size(wtdl)=$(size(wtdl)), size(Mell)=$(size(Mell))")
        #println("dlrec=$dlrec, dlmin=$dlmin")
        #println("idx=$idx, Nell2=$Nell2")
	global t0 += @timed   copy_ixy_ix!(wtdl, idx, Nell2+1, Mell)
        if dlmin < dlrec
            global tm2 += @timed  rec_m2!(c, z, Am0, dlrec, Mell, Mellbp1, idx, work1, work2)
            global tm2s += @timed copy_ixy_i!(wtdl, idx, Nell2, work1)
            global tm4 += @timed  rec_m4!(c, z, Am0, dlrec, wtdl, idx, Nell2, work1, work2)
        end
        if dlmax > dlrec
            M2 = div(dlmax - dlrec, 2)
            global tp2 += @timed  rec_p2!(c, z, Am0, dlrec, Mell, Mellbp1, idx, work1, work2)
            global tp2s += @timed copy_ixy_i!(wtdl, idx, Nell2+2, work1)
            global tp4 += @timed  rec_p4!(c, z, Am0, dlrec, wtdl, idx, Nell2, M2, work1, work2)
        end
end

function compute_wl_Rg1!(wtdl, idx, Am0, C0, dlrec, R, Mell, Mellbp1, work1, work2, dlmin, dlmax)
	M = length(Am0)
	z = R^2
	omz = 1 - z
	Nell2 = max(0, div(dlrec - dlmin, 2))
        M2 = div(dlmax - dlrec, 2)
	wtdl[:,idx,Nell2+1] .= Mell[:,idx]
	# initial dl=-2 recursion:
        if dlmin < dlrec
            c = C0
            cm2 = c - 2
            bma = c - 1 + dlrec
            for i=1:M
                    a = Am0[i] - dlrec/2
                    b = bma + a
                    bm1ma = bma - 1
                    oobm1 = 1 / (b - 1)
                    cmb = 1 - dlrec - a
                    F000 = Mell[i,idx]
                    F010 = Mellbp1[i,idx]
                    F0m10 = (b * omz * F010 - (2b-c-bma*z) * F000) / cmb
                    #println("a=$a, b=$b, c=$c")
                    #println("F0m10: $F0m10")
                    work1[i] = bm1ma * oobm1 * F0m10 - F000
                    work2[i] = - a * F000 * oobm1
            end
            wtdl[:,idx,Nell2] = work1
            # towards dl=-4:
            for j=-2:-1:-Nell2
                    dl2 = j + 2
                    dl = 2 * dl2
                    bma = c - 1 + dlrec + dl
                    bmam3 = bma - 3
                    oobmam1 = 1 / (bmam3+2)
                    cm1 = c - 1
                    for i=1:M
                            a = Am0[i] - dlrec/2 - dl2
                            F000 = work2[i]
                            F1m10 = work1[i]
                            #
                            b = bma + a
                            bm2 = b - 2
                            cmbp1 = c - b + 1
                            cmambp1 = cmbp1 - a
                            F0m10 = ((b-1)*F000 - a*F1m10) * oobmam1
                            F0m20 = (cmambp1*F0m10 + a*omz*F1m10) / cmbp1
                            F1m20 = ((cm1-a)*F0m20 - bm2*omz*F1m10) / cmambp1
                            ap1F2m20 = (bm2*F1m10 - bmam3*F1m20)
                            oobm2 = 1 / bm2
                            Aellratio = - (a+1) * oobm2
                            work1[i] = -oobm2 * ap1F2m20
                            work2[i] = Aellratio * F1m10
                    end
                    wtdl[:,idx,Nell2+j+1] = work1
            end
        end
	# initial dl=2 recursion:
        if dlmax > dlrec
            c = C0
            cm1 = c - 1
            for i=1:M
                    a = Am0[i] - dlrec/2
                    b = cm1 + a + dlrec
                    am1 = a - 1
                    F000 = Mell[i,idx]
                    F010 = Mellbp1[i,idx]
                    b1mzF010 = b * omz * F010
                    cmaFm100 = (c-b-a) * F000 + b1mzF010
                    bcmambFm110 = b * (cm1-b) * cmaFm100 / (c-a) - am1 * b1mzF010
                    oo1ma = - 1 / am1
                    Aellratio = b * oo1ma
                    work1[i] = oo1ma * bcmambFm110 / (c-a-b)
                    work2[i] = Aellratio * F000
            end
            wtdl[:,idx,Nell2+2] = work1
            # towards dl=4:
            for j=2:M2
                    dl2 = j - 2
                    dl = 2 * dl2
                    bma = cm1 + dlrec + dl
                    oobmap1 = 1 / (bma + 1)
                    bmap3 = bma + 3
                    cp1 = c + 1
                    for i=1:M
                            a = Am0[i] - dlrec/2 - dl2
                            b = bma + a
                            #println("a=$a, b=$b, c=$c")
                            am2 = a - 2
                            cmambp1 = cp1 - a - b
                            Fm110 = work1[i]
                            F000 = work2[i]
                            Fm100 = (b * Fm110 - (a-1) * F000) * oobmap1
                            Fm200 = (cmambp1 * Fm100 + b * omz * Fm110) / (cp1-a)
                            Fm210 = ((cm1-b) * Fm200 - am2 * omz * Fm110) / cmambp1
                            bp1Fm220 = bmap3 * Fm210 + am2 * Fm110
                            oo2ma = - 1 / am2
                            Aellratio = (b+1) * oo2ma
                            work1[i] = oo2ma * bp1Fm220
                            work2[i] = Aellratio * Fm110
                    end
                    wtdl[:,idx,Nell2+j+1] = work1
            end
        end
end



function calc_wtdll!(wtRdl, Mell::Array{Complex{Float64},2}, Mellbp1::Array{Complex{Float64},2}, Am0, ell::Integer, dlrec::Integer, dlrecRg1::Integer, dlmin::Integer, dlmax::Integer, RR::Array{Float64,1}, RRnorm::Array{Float64,1}, work1::Array{Complex{Float64},1}, work2::Array{Complex{Float64},1})
	c0 = ell + 3/2
	for j=1:length(RR)
		R = RR[j]
		if R > 1
			compute_wl_Rg1!(wtRdl, j, Am0, c0, dlrecRg1, RRnorm[j], Mell, Mellbp1,
				work1, work2, dlmin, dlmax)
		else
			compute_wl!(wtRdl, j, Am0, c0, dlrec, R, Mell, Mellbp1,
				work1, work2, dlmin, dlmax)
		end
	end
        #println("wtRdl[1,1,1] = ", wtRdl[1,1,1])
        #println("wtRdl[1,1,2] = ", wtRdl[1,1,2])
        #println("wtRdl[1,1,3] = ", wtRdl[1,1,3])
        #println("wtRdl[1,1,4] = ", wtRdl[1,1,4])
        #println("wtRdl[1,1,5] = ", wtRdl[1,1,5])
end


###################### Error estimates (Use with caution!) #########################

# calculate ln[(2n + 1)!!]
function ldblfac_2xp1(n::Integer)
	# 2n+1 is always odd!
	return (n+1) * log(2) + loggamma(n + 1.5) - 0.5 * log(pi)
end


function uellnkrx(ell, n, gkr, x)
	real(exp(0.5im * pi * ell)
	* (im*gkr)^(-2-n)
	* inc_gamma_upper(complex(n+1), im*gkr*x))
end


function fsGkrx(ell, s, G, kr, N, q, x)
	fac = 16N^2 / (9G^2)
	esG = exp(s*G)
	gam = esG^20
	return ((1 - fac) * uellnkrx(ell, q-2, kr*gam, x/gam)
	+ 2fac * (gam / esG) * uellnkrx(ell, q-1, kr*gam, x/gam)
	- fac * (gam / esG)^2 * uellnkrx(ell, q, kr*gam, x/gam))
end


function fsGkr(ell, s, G, kr, N, q)
	gam = exp(20s*G)
	as = 16N^2 / (9G^2) * exp(-2s*G)
	fac = 16N^2 / (9G^2)
	x0 = exp(s*G) - 1/sqrt(as)
	x1 = exp(s*G) + 1/sqrt(as)
	f0 = fsGkrx(ell, s, G, kr, N, q, x0)
	f1 = fsGkrx(ell, s, G, kr, N, q, x1)
	if !isfinite(f0) || !isfinite(f1)
		@error "Infinities!" f0 f1
		@assert false
	end
	return gam^q * (f1 - f0)
end


function estimate_error_xi(pkfn, ell::Int, nu::Int, r::Float64;
		kmin::Float64=1e-4, kmax::Float64=1e4)
	qnu, qbest, qmin, qmax = calc_qbest(ell, nu)
	N = 1024  # we only need a representative sample, not the exact number used
	k = logspace(log10(kmin), log10(kmax), N)
	k0 = kmin
	G = log(kmax / kmin)
	prefac = G / (2pi^2 * N * r^nu)
	k3pk = k.^(3-nu) .* pkfn(k)
	logsm1 = -(ell + qnu) * G + ell * log.(k * r) - ldblfac_2xp1(ell)
	Em1 = prefac * sum(k3pk .* exp.(logsm1))
	Ep1 = prefac * sum(k3pk .* exp.((qnu-1)*G) .* sin.(k*r*exp(G)-pi/2*ell) ./ (k * r))
	#Ep1 = prefac * sum(k3pk .* exp.(qnu*G) .* sphbesj.(k*r*exp(G), ell))
	#Ep1 = prefac * sum(k3pk .* fsGkr.(ell, 1, G, k*r, N, qnu))

	#return Ep1
	return Em1 + Ep1
end


function estimate_aliasingerror_wl(pkfn, ell::Int, dl::Int, chi::Float64, R::Float64;
		q::Float64=1.1, kmin::Float64=1e-4, kmax::Float64=1e4)
	ell1 = ell
	ell2 = ell + dl
	N = 32  # we only need a representative sample, not the exact number used
	k = logspace(log10(kmin), log10(kmax), N)
	k0 = kmin
	G = log(kmax / kmin)
	prefac = 2 * G / (pi * N)
        pk = pkfn(k)
	k3pk = k.^3 .* pk

	sm1 = exp.(-(q + ell1 + ell2) * G
		+ ell2 * log(R)
		+ (ell1 + ell2) * log.(k * chi)
		- ldblfac_2xp1(ell1)
		- ldblfac_2xp1(ell2))
	#sm1 = exp.(-q*G) .* sphbesj(k.*chi*exp(-G), ell1) .* sphbesj(k.*R*chi*exp(-G), ell2)
	sp1 = exp.((q - 2) * G
		- log(R)
		- 2 * log.(k * chi))
	#sp1 = exp.(q*G) .* sphbesj(k.*chi*exp(G), ell1) .* sphbesj(k.*R*chi*exp(G), ell2)

	Em1 = prefac * sum(k3pk .* sm1) / (1 - exp(-(q + ell1 + ell2)*G))
	Ep1 = prefac * sum(k3pk .* sp1) / (2 * (1 - exp((q-2)*G)))

	return Em1, Ep1
end

function estimate_roundofferror_wl(pkfn, ell::Int, dl::Int, chi::Float64, R::Float64;
		q::Float64=1.1, kmin::Float64=1e-4, kmax::Float64=1e4, chi0::Float64=1.0)
	ell1 = ell
	ell2 = ell + dl
	N = 32  # we only need a representative sample, not the exact number used
	k = logspace(log10(kmin), log10(kmax), N)
	k0 = kmin
	G = log(kmax / kmin)
        alpha = k0 * chi0
        pk = pkfn(k)

        lgams = (loggamma(2 - q)
            + loggamma((ell1 + ell2 + q) / 2)
            - loggamma((4 + ell1 + ell2 - q) / 2)
            - loggamma((3 + ell1 - ell2 - q) / 2)
            - loggamma((3 + ell2 - ell1 - q) / 2))
        Mll = alpha^(-q) * 2.0^(q-3) * pi * exp(lgams)
	k3qpk = (k / k0).^(3-q) .* pk
        L = 2pi * N / G
        phi0 = sum(k3qpk) / L
	prefac = (4 * k0^3 / G) * (chi / chi0).^(-q)
	Eprec = 1e-10 * abs(prefac * phi0 * Mll)

	return Eprec  # nah, don't trust it!
end

function estimate_wlerr(pkfn, ell::Int, dl::Int, chi::Float64, R::Float64;
		q=1.1, kmin::Float64=1e-4, kmax::Float64=1e4, chi0::Float64=1.0)
    return (
    sum(estimate_aliasingerror_wl(pkfn, ell, dl, chi, R;
    q=Float64(q), kmin=kmin, kmax=kmax))
    + estimate_roundofferror_wl(pkfn, ell, dl, chi, R;
    q=Float64(q), kmin=kmin, kmax=kmax, chi0=chi0))
end


function estimate_wljjerr(pkfn, ell::Integer, chi, R::Float64;
		q=1.1, kmin::Float64=1e-4, kmax::Float64=1e4, chi0::Float64=1.0)
	errest(ell1, ell2) = estimate_wlerr.(pkfn, ell1, ell2-ell1, chi, R;
			q=q, kmin=kmin, kmax=kmax, chi0=chi0)
	L = ell
	wldl = Dict()
	wldl[-2,-2] = errest(L-2, L-2)
	wldl[-2, 0] = errest(L-2, L)
	wldl[-2, 2] = errest(L-2, L+2)
	wldl[ 0,-2] = errest(L, L-2)
	wldl[ 0, 0] = errest(L, L)
	wldl[ 0, 2] = errest(L, L+2)
	wldl[ 2,-2] = errest(L+2, L-2)
	wldl[ 2, 0] = errest(L+2, L)
	wldl[ 2, 2] = errest(L+2, L+2)

	we00 = wljj_dl(L, 0, 0, wldl; abs_coeff=true)
	we02 = wljj_dl(L, 0, 2, wldl; abs_coeff=true)
	we20 = wljj_dl(L, 2, 0, wldl; abs_coeff=true)
	we22 = wljj_dl(L, 2, 2, wldl; abs_coeff=true)

	return we00, we02, we20, we22
end


########################## utilities ##################################

function calc_ellenlarged(ell, jmax)
	ellenlarged = Array{Int}(undef, (2jmax + 1) * length(ell))
	ll = 1
	for i=1:length(ell)
		for j=-jmax:jmax
			ellenlarged[ll] = ell[i] + j
			ll += 1
		end
	end
	ellenlarged = unique(sort(ellenlarged))
	#if ell[end] >= 2
		#@assert ellenlarged[1] >= 0
	#end
	return ellenlarged
end


# function to read "name = value" pairs from a file, and convert it to the
# types in the struct 'T'
function struct_read_fieldnames(filename::AbstractString, T::Type; remove_comment_leader=false)
    values = Dict()
    names = fieldnames(T)
    open(filename) do f
        for ln in eachline(f)
            s = split(ln, "=")
            length(s) == 1 && continue
            n, v = s
            (remove_comment_leader && n[1] == '#') && (n = n[2:end])
            n = Symbol(strip(n))
            v = strip(v)
            values[n] = try
                parse(fieldtype(T, n), v)
            catch
                v
            end
        end
    end
    return values
end


##################### fell_lmax cache ###########################

struct F21EllCache
	ℓ::Int
	Δℓ::Int
	ΔℓRg1::Int
	N::Int
	q::Float64
	kmin::Float64
	kmax::Float64
	χ0::Float64
	RR::Array{Float64,1}
	ℓmax::Array{Int,2}
	f21::Array{ComplexF64,3}
end


function F21EllCache(ℓ::Int, RR, N=1600; q=1.1, kmin=1e-5, kmax=1e3, χ0=1e-3,
		     Δℓ=4, ΔℓRg1=-4)
	alpha = kmin * χ0
	G = log(kmax / kmin)
	N2 = div(N, 2) + 1
	mm = 0:N2-1
	f21 = Array{Complex{Float64}}(undef, 2, length(mm), length(RR))
	ℓmax = Array{Int64}(undef, length(mm), length(RR))
	for j=1:length(RR)
		R = RR[j]
		print("  q=$q, R=$R:\t")
		@time for i=1:length(mm)
			m = mm[i]
			Δℓr = R > 1 ? ΔℓRg1    : Δℓ
			ell1 = ℓ
			ell2 = ℓ + Δℓr
			ell = R > 1 ? ell2        : ell1
			Δℓr = R > 1 ? ell1 - ell2 : ell2 - ell1
			al  = R > 1 ? R*alpha     : alpha
			Rn  = R > 1 ? 1/R         : R
			f21[:,i,j], ℓmax[i,j] = calc_2f1_RqmG(ell, Rn, Δℓr;
							      q=q, m=m, G=G,
							      alpha=al)
			if R > 1
				ℓmax[i,j] += Δℓr  # switch ell1 <-> ell2
			end
		end
	end
	println()
	F21EllCache(ℓ, Δℓ, ΔℓRg1, N, q, kmin, kmax, χ0, RR, ℓmax, f21)
end


function write(dname::AbstractString, t::F21EllCache)
	mkpath(dname)
	s = ""
	for n in fieldnames(typeof(t))
		field = getfield(t, n)
		if typeof(field) <: AbstractArray
			if n == :RR
				ftmp = "$dname/$(string(n)).tsv"
				writedlm(ftmp, field)
			else
				ftmp = "$dname/$(string(n)).bin"
				write(ftmp, field)
			end
			field = relpath(ftmp, dname)
		end
		ln = "$(string(n)) = $field\n"
		print(ln)
		s *= ln
	end
	fname = "$dname/F21EllCache.dat"
	write(fname, s)
end


function F21EllCache(dname::AbstractString)
	# read singular values
	fname = "$dname/F21EllCache.dat"
	values = struct_read_fieldnames(fname, F21EllCache; remove_comment_leader=false)

	# read arrays
	# check absolute paths for backward compatibility
	(values[:RR][1] != '/') && (values[:RR] = "$dname/$(values[:RR])")
	(values[:ℓmax][1] != '/') && (values[:ℓmax] = "$dname/$(values[:ℓmax])")
	(values[:f21][1] != '/') && (values[:f21] = "$dname/$(values[:f21])")
	N2 = div(values[:N], 2) + 1
	values[:RR] = readdlm(values[:RR])[:]
	lenRR = length(values[:RR])
	values[:ℓmax] = read!(values[:ℓmax], Array{Int}(undef, N2, lenRR))
	values[:f21] = read!(values[:f21], Array{Complex{Float64}}(undef, 2, N2, lenRR))

	# put in correct order
	names = fieldnames(F21EllCache)
	vals = [values[n] for n in names]

	# create struct
	F21EllCache(vals...)
end


# for compatibility
function read_fell_lmax(fell_lmax_file)
	cache = F21EllCache(fell_lmax_file)
	N2 = div(cache.N, 2) + 1
	fell = cache.f21
	flmax = cache.ℓmax
	mm = 0:N2-1
	RRcache = cache.RR
	lmaxcache = cache.ℓ
	return fell, flmax, mm, RRcache, lmaxcache
end


############### Ml-cache ##########################

const magic_number = 0x782aa138291e1800
function write_MlCache_header(fname, Mell, RR, ell)
	@assert typeof(Mell) == Array{ComplexF64,3}
	f = open(fname, "w")
	write(f, Int64(magic_number))
	write(f, Int64(size(Mell,1)))
	write(f, Int64(size(Mell,2)))
	write(f, Int64(size(Mell,3)))
	write(f, Int64(length(ell)))
	write(f, Array{Int64}(sort(ell, rev=true)))
	write(f, Array{Float64}(RR))
	return f
end

function write_MlCache_record(f, Mell)
	@assert typeof(Mell) == Array{ComplexF64,3}
	write(f, Mell)
end

function read_MlCache_header(fname="Ml21-cache.bin")
	f = open(fname, "r")
	magic, lenmm, lenRR, lenjj, lenell = read!(f, Array{Int64}(undef, 5))
	@assert magic == magic_number
	Mlsize = [lenmm, lenRR, lenjj]
	ell = read!(f, Array{Int64}(undef, lenell))
	RR = read!(f, Array{Float64}(undef, lenRR))
	return f, Mlsize, ell, RR
end

function read_MlCache_record!(f, Mell)
	@assert typeof(Mell) == Array{ComplexF64,2}
	read!(f, Mell)
end


############### nicer MlCache ##########################

function thin_rr(rr, rmin, rmax, Δrmin)
    rridx = fill(false, length(rr))
    ilast = -1
    firstin = true
    firstout = true
    for i=length(rr):-1:1
        if rmin <= rr[i] <= rmax
            if firstin
                if i < length(rr)
                    rridx[i+1] = true
                end
                rridx[i] = true
                ilast = i
                firstin = false
            else
                Δr = abs(rr[i] - rr[ilast])
                if Δr >= Δrmin
                    rridx[i] = true
                    ilast = i
                end
            end
        elseif firstout && rr[i] < rmin
            rridx[i] = true
            firstout = false
        end
    end
    return rridx
end


function bools2idxs(bools)
    idxs = Int[]
    for i=1:length(bools)
        if bools[i]
            push!(idxs, i)
        end
    end
    return idxs
end


struct MlCache
    dir::AbstractString
    f21ellcache_dir::AbstractString
    MlCache_file::AbstractString
    rr_file::AbstractString
    RR_file::AbstractString
    ℓℓ_file::AbstractString
    rr_thinning_rmin::Float64
    rr_thinning_rmax::Float64
    rr_thinning_Δrmax::Float64
end


function MlCache(ell, f21ellcache_dir::AbstractString, dir="cache/MlCache";
                 rr_thinning=(-Inf, Inf, 0.0))
    mkpath(dir)
    MlCache_file = "$dir/MlCache.bin"
    rr_file = "$dir/rr.tsv"
    RR_file = "$dir/RRatio.tsv"  # macosx is by default case-insensitive, so give it a distinct name
    ℓℓ_file = "$dir/ell.tsv"

    f21ellcache = F21EllCache(f21ellcache_dir)
    RR = f21ellcache.RR
    kmin = f21ellcache.kmin
    kmax = f21ellcache.kmax
    N = f21ellcache.N
    chi0 = f21ellcache.χ0
    q = f21ellcache.q

    # calculate all M_ll, result gets saved to a file:
    ell = unique(sort(ell))
    tt = calcMljj(RR; ell=ell, kmin=kmin, kmax=kmax, N=N, r0=chi0, q=q,
                  fell_lmax_file=f21ellcache_dir, outfile=MlCache_file)

    # get rr and ridxs
    χχ = calcwljj(k->1.0, RR; ell=[-1], kmin=kmin, kmax=kmax, N=N, r0=chi0,
		  q=q, cachefile=MlCache_file)
    ridxs = bools2idxs(thin_rr(χχ, rr_thinning...))
    rr = χχ[ridxs]

    writedlm(rr_file, [rr ridxs])
    writedlm(RR_file, RR)
    writedlm(ℓℓ_file, ell)

    MlCache(dir, f21ellcache_dir, MlCache_file, rr_file, RR_file, ℓℓ_file,
            rr_thinning...)
end


function write(dname::AbstractString, t::MlCache)
    s = ""
    for n in fieldnames(MlCache)
        v = getfield(t, n)
	if typeof(v) <: AbstractString
            v = relpath(v, dname)
	end
        s *= "$(string(n)) = $v\n"
    end
    write("$dname/MlCache.dat", s)
end


function MlCache(dir::AbstractString)
    fname = "$dir/MlCache.dat"
    values = struct_read_fieldnames(fname, MlCache; remove_comment_leader=false)
    names = fieldnames(MlCache)
    for n in names
        t = fieldtype(MlCache, n)
        if t <: AbstractString
            if values[n][1] != '/'  # backwards compatibility
                values[n] = realpath("$dir/$(values[n])")
            end
        end
    end
    vals = [values[n] for n in names]
    MlCache(vals...)
end


######################### fast multiply-copy-add operations ##############

function copyconvertcond!(wjj, Mell32, ll)
	@assert size(Mell32,4) >= ll >= 1
	@assert size(Mell32,3) == size(wjj,3)
	@assert size(Mell32,2) == size(wjj,2)
	@assert size(Mell32,1) == size(wjj,1)
	for k=1:size(Mell32,3), j=1:size(Mell32,2), i=1:size(Mell32,1)
		@inbounds Mell32[i,j,k,ll] = wjj[i,j,k]
	end
end


function mymult!(M, x, n)
	@assert length(x) == size(M,1)
	@assert n <= size(M,2)
	for j=1:n, i=1:length(x)
		@inbounds M[i,j] *= x[i]
	end
end

function brfft_exec!(w, wt, brfft_plan, N)
	for i=1:N
		#w[:,i] = brfft_plan * wt[:,i]
		mul!(view(w, :, i), brfft_plan, view(wt,:,i))
	end
end

function mymult_A_B_x!(Y, M, x, idxs, n)
        @assert length(idxs) >= length(x)
        @assert size(Y,1) >= length(x)
        @assert size(Y,2) >= n
        imin, imax = extrema(idxs)
        @assert imin >= 1
        @assert size(M,1) >= imax
        @assert size(M,2) >= n
	for i=1:n, j=1:length(x)
		@inbounds Y[j,i] = M[idxs[j],i] * x[j]
	end
end


######################### public functions

function make_fell_lmax_cache(RR, ellmax::Integer, dname="f21ellcache";
		N=1024, q=1.0, G=log(1e4/1e-4), r0=1.0, k0=1e-4, dlrec=4, dlrecRg1=-4)
	ellmax += 2
	println("Calculating fmax: ")
        println("  dlrec    = $dlrec")
        println("  dlrecRg1 = $dlrecRg1")
	@time cache = F21EllCache(ellmax, RR, N; q=q, kmin=k0,
				  kmax=k0*exp(G), χ0=r0, Δℓ=dlrec,
				  ΔℓRg1=dlrecRg1)
	write(dname, cache)
end


function calcMljj(RR;
		kmin=1e-4, kmax=1e4, ell=42:42, jmax=2, r0=1.0, N=1024, q=1.0,
		dlrec=4, dlrecRg1=-4, dlmin=-4, dlmax=4,
		fell_lmax_file="fell_lmax_v23.fits",
		outfile="Ml21-cache.bin",
		TMell=Float64,
	)

	if length(ell) > 1
		ell = sort(ell)
	end
	ellenlarged = calc_ellenlarged(ell, jmax)

	N2 = div(N, 2) + 1
	k0 = kmin
	G = log(kmax / kmin)
	alpha = k0 * r0
	#println("ell: $ell")
	println("kmin = $kmin")
	println("kmax = $kmax")
        println("dlrec    = $dlrec")
        println("dlrecRg1 = $dlrecRg1")

	mm = 0:N2-1
	tt = 2pi * mm / G
	Am0 = @. (q - 1) / 2 - im * tt / 2

	Mell = Array{Complex{Float64}}(undef, length(mm), length(RR))
	Mellbp1 = Array{Complex{Float64}}(undef, length(mm), length(RR))

	ndl = div(dlmax - dlmin, 2) + 1
	work1 = Array{Complex{Float64}}(undef, size(Mell,1))
	work2 = Array{Complex{Float64}}(undef, size(Mell,1))
	wtRdll = Dict{Int,Array{Complex{Float64},3}}()
	for i=-jmax:jmax
		wtRdll[i] = Array{Complex{Float64}}(undef, length(mm), length(RR), ndl)  # tt, RR, dl
	end
	wjj = Array{Complex{Float64}}(undef, length(mm), length(RR), 4)  # tt, RR, jj'

	Mellsize = length(mm) * length(RR) * 4 * length(ell) * sizeof(Complex{TMell}(1))
	println("Output size: $(Mellsize) bytes = $(Mellsize/2^30) GiB")
	println("Output size: $(sizeof(wjj)) bytes = $(sizeof(wjj)/2^30) GiB")
	#Mell32[:] = 0.0  # for testing
	f = write_MlCache_header(outfile, wjj, RR, ell)

	print("Reading '$fell_lmax_file'... ")
	@time fell, flmax, mm, RRcache, lmaxcache = read_fell_lmax(fell_lmax_file)
	ellmax = max(maximum(ellenlarged), maximum(lmaxcache))
	println("ellmax: $ellmax")
	println("lmaxcache: $lmaxcache")
	@assert length(mm) == N2
	@assert all(RRcache .== RR)
	RRnorm = deepcopy(RR)
	RRnorm[RR.>1] = 1 ./ RR[RR.>1]
        println("fell[:,1,1] = ", fell[:,1,1])

	# backward recursion
	tstep = @timed Nothing
	tswapping = @timed Nothing
	tcalcMl = @timed Nothing
	tcalcwl = @timed Nothing
	tcalcwljj = @timed Nothing
	tcalcprefac = @timed Nothing
	tout = @timed Nothing
	twrite = @timed Nothing
	ttest = @timed Nothing
	global t0 = @timed Nothing
	global tm2 = @timed Nothing
	global tm2s = @timed Nothing
	global tm4 = @timed Nothing
	global tp2 = @timed Nothing
	global tp2s = @timed Nothing
	global tp4 = @timed Nothing
	ll = length(ell)
	llen = length(ellenlarged)
	timing = time()
	@time for ellnow in ellmax:-1:minimum(ellenlarged)
		#println("ellnow: $ellnow")
		if ellnow == ellenlarged[llen]
			print("ell $ellnow, ")
			println("elapsed: ", time() - timing)
			timing = time()
			tcalcMl += @timed calc_Mellell_lmax!(ellnow, fell, flmax,
				Mell, Mellbp1)
			tcalcwl += @timed calc_wtdll!(wtRdll[-jmax], Mell, Mellbp1,
				Am0, ellnow, dlrec, dlrecRg1, dlmin, dlmax, RR, RRnorm,
                                work1, work2)
			llen -= 1
		end
		if ellnow == ell[ll] - jmax
			# now we have everything together to calculate for ell=ellnow+jmax
			tcalcwljj += @timed wljj_from_wldl!(wtRdll[-2], wtRdll[0], wtRdll[2],
				ellnow + jmax, wjj)
			twrite += @timed write_MlCache_record(f, wjj)
			ll -= 1
		end

		tstep += @timed stepback!(RR, ellnow, Am0, dlrec, fell, flmax)
		tstep += @timed stepbackRg1!(RR, ellnow, Am0, dlrecRg1, fell, flmax)
		tswapping += @timed begin  # just renaming, shouldn't take much time:
			wtmp = wtRdll[jmax]
			for i=jmax:-1:-jmax+1
				wtRdll[i] = wtRdll[i-1]
			end
			wtRdll[-jmax] = wtmp
		end
	end
	println("elapsed: ", time() - timing)
	println("step:          ", tstep)
	println("swapping:      ", tswapping)
	println("calc_Mellell!: ", tcalcMl)
	println("  t0 :  ", t0)
	println("  tm2 : ", tm2)
	println("  tm2s: ", tm2s)
	println("  tm4 : ", tm4)
	println("  tp2 : ", tp2)
	println("  tp2s: ", tp2s)
	println("  tp4 : ", tp4)
	println("calc_wtdll!:   ", tcalcwl)
	println("calc_wljj!:    ", tcalcwljj)
	println("mult_prefac!:  ", tcalcprefac)
	println("convert:       ", tout)
	println("write:         ", twrite)
	println("test_rand_2f1: ", ttest)

	print("Closing outfile $outfile... ")
	@time close(f)

	#print("calcMljj:")
	return tt
end


function calcwljj(pkfn, RR; ell=42:42, kmin=1e-4, kmax=1e4, r0=1.0, N=1024, q=1.0,
		ridxs=1:typemax(Int),
		#winx=one, wink=one,
		winx=windowfn, wink=windowfn,
		fftw_flags=FFTW.MEASURE, fftw_timelimit=Inf,
		cachefile="Ml21-cache.bin",
		outfunc=(a,b,c,d)->Nothing,
	)
	if maximum(ridxs) > N
		ridxs = minimum(ridxs):N
	end
	N2 = div(N,2) + 1
	Nrr = length(ridxs)
	k0 = kmin
	G = log(kmax / kmin)
	L = 2 * pi * N / G
	rr = @. r0 * exp((ridxs-1) * (G / N))

	if maximum(ell) < 0  # this is our code that we are only interested in 'rr'
		return rr
	end

	prefac = @. (4 * k0^3 / G) * (rr / r0)^(-q)
	@time brfft_plan = plan_brfft(Array{Complex{Float64}}(undef, N2), N;
		flags=fftw_flags, timelimit=fftw_timelimit)
	print("make_phi(): ")
	@time phi = make_phi(pkfn, k0, N, L, q, winx, wink)

	wt00 = Array{Complex{Float64}}(undef, N2, length(RR))
	wt02 = Array{Complex{Float64}}(undef, N2, length(RR))
	wt20 = Array{Complex{Float64}}(undef, N2, length(RR))
	wt22 = Array{Complex{Float64}}(undef, N2, length(RR))
	wr00 = Array{Float64}(undef, N, length(RR))
	wr02 = Array{Float64}(undef, N, length(RR))
	wr20 = Array{Float64}(undef, N, length(RR))
	wr22 = Array{Float64}(undef, N, length(RR))
	w00 = Array{Float64}(undef, Nrr, length(RR))
	w02 = Array{Float64}(undef, Nrr, length(RR))
	w20 = Array{Float64}(undef, Nrr, length(RR))
	w22 = Array{Float64}(undef, Nrr, length(RR))

	tread = @timed f, Mlsize, ellcache, RRcache = read_MlCache_header(cachefile)
	@assert Mlsize[1] == size(wt00,1)
	@assert Mlsize[2] == size(wt00,2)
	@assert Mlsize[3] == 4
	#println("ellcache: $ellcache")
	#println("ell: $ell")
	#@assert all(ellcache .== ell)
	@assert all(RRcache .== RR)
	lenRR = length(RR)
	toutfunc = @timed Nothing

	tskip = @timed Nothing
	tmultphi = @timed Nothing
	tbrfft = @timed Nothing
	tmultprefac = @timed Nothing

	@time for ll in ellcache
		tskip += @timed begin
			if ll ∉ ell
				# skip ahead in 'f'
				skip(f, sizeof(wt00))
				skip(f, sizeof(wt02))
				skip(f, sizeof(wt20))
				skip(f, sizeof(wt22))
				continue
			end
		end
		#tic()
		tread += @timed begin
			read_MlCache_record!(f, wt00)
			read_MlCache_record!(f, wt02)
			read_MlCache_record!(f, wt20)
			read_MlCache_record!(f, wt22)
		end
		tmultphi += @timed begin
			mymult!(wt00, phi, lenRR)
			mymult!(wt02, phi, lenRR)
			mymult!(wt20, phi, lenRR)
			mymult!(wt22, phi, lenRR)
		end
		tbrfft += @timed begin
			brfft_exec!(wr00, wt00, brfft_plan, lenRR)
			brfft_exec!(wr02, wt02, brfft_plan, lenRR)
			brfft_exec!(wr20, wt20, brfft_plan, lenRR)
			brfft_exec!(wr22, wt22, brfft_plan, lenRR)
		end
		tmultprefac += @timed begin
			mymult_A_B_x!(w00, wr00, prefac, ridxs, lenRR)
			mymult_A_B_x!(w02, wr02, prefac, ridxs, lenRR)
			mymult_A_B_x!(w20, wr20, prefac, ridxs, lenRR)
			mymult_A_B_x!(w22, wr22, prefac, ridxs, lenRR)
		end
		toutfunc += @timed begin
			outfunc((w00, w02, w20, w22), ll, rr, view(RR,1:lenRR))
		end
		#print("ell=$ll: ")
		#toc()
	end

	println("tskip:       ", tskip)
	println("tread:       ", tread)
	println("tmultphi:    ", tmultphi)
	println("tbrfft:      ", tbrfft)
	println("tmultprefac: ", tmultprefac)
	println("toutfunc:    ", toutfunc)

	close(f)

	#print("calcwljj: ")
	return rr
end


end # module


# vim : set sw=4 et sts=4 :
