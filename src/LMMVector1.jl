## A linear mixed model with a single vector-valued random-effects term

type LMMVector1 <: LinearMixedModel
    ldL2::Float64
    L::Array{Float64,3}
    RX::Cholesky{Float64}
    RZX::Array{Float64,3}
    Xt::Matrix{Float64}
    XtX::Matrix{Float64}
    Xty::Vector{Float64}
    Ztrv::Vector
    Ztnz::Matrix{Float64}
    ZtX::Array{Float64,3}
    ZtZ::Array{Float64,3}
    Zty::Matrix{Float64}
    beta::Vector{Float64}
    fname::String
    lower::Vector{Float64}
    lambda::Matrix{Float64}
    mu::Vector{Float64}
    u::Matrix{Float64}
    y::Vector
    REML::Bool
    fit::Bool
end

function LMMVector1(X::ModelMatrix, Xs::Matrix, rv::Vector, y::Vector, fname::String)
    Xt = X.m'; p,n = size(Xt); Ztnz = Xs'
    n == length(rv) == size(Ztnz,2) == length(y) || error("Dimension mismatch")
    k = size(Ztnz,1) # number of random effects per grouping factor level
    k > 1 || error("Use LMMScalar1, not LMMVector1")
    urv = unique(rv)
    isperm(urv) || error("unique(rv) must be a permutation")
    nl = length(urv)
    ZtZ = zeros(k,k,nl); ZtX = zeros(k,p,nl); Zty  = zeros(k,nl)
    for j in 1:n
        i = rv[j]; z = Ztnz[:,j]; ZtZ[:,:,i] += z*z';
        Zty[:,i] += y[j]*z; ZtX[:,:,i] += z*Xt[:,j]'
    end
    pos = 0; lower_bound = zeros(k*(k+1)>>1)
    for j in 1:k, i in j:k lower_bound[pos += 1] = i == j ? 0. : -Inf end
    XtX = Xt * Xt'
    LMMVector1(0., zeros(k,k,nl), cholfact(XtX,:U), similar(ZtX), Xt, XtX,
               Xt*y, rv, Ztnz, ZtX, ZtZ, Zty, zeros(p), fname, lower_bound,
               eye(k), zeros(n), zeros(k,nl), y, false, false)
end

cholfact(m::LMMVector1,RX=true) = RX ? m.RX : error("not yet written")

## cor(m) -> correlation matrices of variance components
cor(m::LMMVector1) = [cc(m.lambda)]

grplevels(m::LMMVector1) = [size(m.u,2)]

isscalar(m::LMMVector1) = size(m.Ztnz, 1) <= 1

## linpred!(m) -> m   -- update mu
function linpred!(m::LMMVector1)
    gemv!('T',1.,m.Xt,m.beta,0.,m.mu)   # initialize to X*beta
    bb = trmm('L','L','N','N',1.,m.lambda,m.u) # b = Lambda * u
    k = size(bb,1)
    for i in 1:length(m.mu)
        m.mu[i] += dot(sub(bb,1:k,int(m.Ztrv[i])), sub(m.Ztnz,1:k,i)) end
    m
end

## Logarithm of the determinant of the generator matrix for the Cholesky factor, RX or L
logdet(m::LMMVector1,RX=true) = RX ? logdet(m.RX) : m.ldL2
    
lower(m::LMMVector1) = m.lower

##  ranef(m) -> vector of matrices of random effects on the original scale
##  ranef(m,true) -> vector of matrices of random effects on the U scale
function ranef(m::LMMVector1, uscale=false)
    uscale && return [m.u]
    [trmm('L','L','N','N',1.,m.lambda,m.u)]
end
    
size(m::LMMVector1) = (length(m.y), length(m.beta), length(m.u), 1)

## solve!(m) -> m : solve PLS problem for u given beta
## solve!(m,true) -> m : solve PLS problem for u and beta
function solve!(m::LMMVector1, ubeta=false)
    n,p,q = size(m); k,nl = size(m.u); copy!(m.u,m.Zty)
    trmm!('L','L','T','N',1.,m.lambda,m.u)
    for l in 1:nl                       # cu := L^{-1} Lambda'Z'y
        trsv!('L','N','N',sub(m.L,1:k,1:k,l), sub(m.u,1:k,l))
    end
    if ubeta
        copy!(m.beta,m.Xty); copy!(m.RZX,m.ZtX); copy!(m.RX.UL, m.XtX)
        trmm!('L','L','T','N',1.,m.lambda,reshape(m.RZX,(k,p*nl))) # Lambda'Z'X
        for l in 1:nl
            wL = sub(m.L,1:k,1:k,l); wRZX = sub(m.RZX,1:k,1:p,l)
            trsm!('L','L','N','N',1.,wL,wRZX) # solve for l'th face of RZX
            gemv!('T',-1.,wRZX,sub(m.u,1:k,l),1.,m.beta) # downdate m.beta
            syrk!('U','T',-1.,wRZX,1.,m.RX.UL)           # downdate XtX
        end
        _, info = potrf!('U',m.RX.UL) # Cholesky factor RX
        bool(info) && error("Downdated X'X is not positive definite")
        solve!(m.RX,m.beta)           # beta = (RX'RX)\(downdated X'y)
        for l in 1:nl                 # downdate cu
            gemv!('N',-1.,sub(m.RZX,1:k,1:p,l),m.beta,1.,sub(m.u,1:k,l))
        end
    end
    for l in 1:nl                     # solve for m.u
        trsv!('L','T','N',sub(m.L,1:k,1:k,l), sub(m.u,1:k,l))
    end
    linpred!(m)
end        

## sqrlenu(m) -> total squared length of m.u (the penalty in the PLS problem)
sqrlenu(m::LMMVector1) = sumsq(m.u)

## std(m) -> Vector{Vector{Float64}} estimated standard deviations of variance components
std(m::LMMVector1) = scale(m)*push!(copy(vec(vnorm(m.lambda,2,1))),1.)

theta(m::LMMVector1) = ltri(m.lambda)

##  theta!(m,th) -> m : install new value of theta, update L 
function theta!(m::LMMVector1, th::Vector{Float64})
    all(th .>= m.lower) || error("theta = $th violates lower bounds")
    n,p,q,t = size(m); k,nl = size(m.u); pos = 1
    for j in 1:k, i in j:k
        m.lambda[i,j] = th[pos]; pos += 1
    end
    ldL = 0.; copy!(m.L,m.ZtZ)
    trmm!('L','L','T','N',1.,m.lambda,reshape(m.L,(k,q)))
    for l in 1:nl
        wL = sub(m.L,1:k,1:k,l)
        trmm!('R','L','N','N',1.,m.lambda,wL) # lambda'(Z'Z)_l*lambda
        for j in 1:k; wL[j,j] += 1.; end      # Inflate the diagonal
        _, info = potrf!('L',wL)        # i'th diagonal block of L_Z
        bool(info) && error("Cholesky decomposition failed at i = $i")
        for j in 1:k ldL += log(wL[j,j]) end
    end
    m.ldL2 = 2.ldL
    m
end
    
