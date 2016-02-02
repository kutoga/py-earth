# distutils: language = c
# cython: cdivision = True
# cython: boundscheck = False
# cython: wraparound = False
# cython: profile = True
from statsmodels.sandbox.nonparametric.tests.ex_smoothers import weights


cimport cython
import numpy as np
import scipy as sp
from libc.math cimport sqrt
from libc.math cimport log
cimport numpy as cnp
from _types import INDEX, FLOAT
from _util cimport log2


@cython.final
cdef class SingleWeightDependentData:
    def __init__(SingleWeightDependentData self, UpdatingQT updating_qt, FLOAT_t[:] w, INDEX_t m, 
                 INDEX_t k, INDEX_t max_terms):
        self.updating_qt = updating_qt
        self.w = w
        self.m = m
        self.k = k
        self.max_terms = max_terms
        self.Q_t = self.updating_qt.Q_t
    
    @classmethod
    def alloc(cls, FLOAT_t[:] w, INDEX_t m, INDEX_t max_terms):
        cdef UpdatingQT updating_qt = UpdatingQT.alloc(m, max_terms)
        return cls(updating_qt, w, m, 0, max_terms)
    
    cpdef int update_from_basis_function(SingleWeightDependentData self, BasisFunction bf, FLOAT_t[:,:] X, 
                                         BOOL_t[:,:] missing, FLOAT_t zero_tol) except *:
        if self.k >= self.max_terms:
            return -1
        bf.apply(X, missing, self.Q_t[self.k, :])
        return self._update(zero_tol)
                            
    cpdef int update_from_array(SingleWeightDependentData self, FLOAT_t[:] b, FLOAT_t zero_tol) except *:
        if self.k >= self.max_terms:
            return -1
        
        self.updating_qt.update(b)
        self.k += 1
#         cdef INDEX_t j
#         for j in range(self.m):
#             self.Q_t[self.k,j] = self.w[j] * b[j]
#         return self._update(zero_tol)
#     
#     cpdef int _update(SingleWeightDependentData self, FLOAT_t zero_tol):
#         # Compute the new householder reflection
#         np.asarray(self.Q_t)[self.k, :] = self.householder.apply_transpose(self.Q_t[self.k, :])
#         self.householder.push_from_column(self.Q_t[self.k, self.k], self.Q_t[self.k,(self.k + 1):])
#         
#         # Create the new row in Q_t and apply all existing householder reflections
#         # including the new one
#         self.Q_t[self.k, :] = 0.
#         self.Q_t[self.k, self.k] = 1.
#         np.asarray(self.Q_t)[self.k, :] = self.householder.apply(self.Q_t[self.k, :])
#         
#         self.k += 1
        
    cpdef downdate(SingleWeightDependentData self):
        self.updating_qt.downdate()
        self.k -= 1
    
    cpdef reweight(SingleWeightDependentData self, FLOAT_t[:] w, FLOAT_t[:,:] B, INDEX_t k, 
                   FLOAT_t zero_tol):
        cdef INDEX_t i
        self.w = w
        self.k = 0
        self.updating_qt.reset()
        for i in range(k):
            self.update_from_array(B[:, i], zero_tol)
        
@cython.final
cdef class MultipleOutcomeDependentData:
    def __init__(MultipleOutcomeDependentData self, list outcomes, list weights):
        self.outcomes = outcomes
        self.weights = weights
        
    @classmethod
    def alloc(cls, FLOAT_t[:,:] y, w, INDEX_t m, INDEX_t n_outcomes, INDEX_t max_terms):
        cdef list weights
        cdef list outcomes
        cdef int i, n_weights
        # w is a numpy array of weights
        if len(w.shape) == 2 and w.shape[1] == n_outcomes:
            n_weights = w.shape[1]
            weights = []
            for i in range(w.shape[1]):
                weights.append(SingleWeightDependentData.alloc(w[:, i], m, max_terms))
        elif len(w.shape) == 1 or w.shape[1] == 1:
            n_weights = 1
            if len(w.shape) == 1:
                weights = [SingleWeightDependentData.alloc(w, m, max_terms)]
            else:
                weights = [SingleWeightDependentData.alloc(w[:, 0], m, max_terms)]
        else:
            raise ValueError('Shape of weights does not match shape of outcomes.')
        
        outcomes = []
        for i in range(n_outcomes):
            outcomes.append(SingleOutcomeDependentData.alloc(y[:, i], weights[i % n_weights], m, max_terms))
        
        return cls(outcomes, weights)
    
    cpdef update_from_array(MultipleOutcomeDependentData self, FLOAT_t[:] b, FLOAT_t zero_tol):
        cdef SingleWeightDependentData weight
        cdef SingleOutcomeDependentData outcome
        for weight in self.weights:
            weight.update_from_array(b, zero_tol)
        for outcome in self.outcomes:
            outcome.update(zero_tol)
    
    cpdef downdate(MultipleOutcomeDependentData self):
        cdef SingleWeightDependentData weight
        cdef SingleOutcomeDependentData outcome
        for weight in self.weights:
            weight.downdate()
        for outcome in self.outcomes:
            outcome.downdate()
            
    cpdef list sse(MultipleOutcomeDependentData self):
        return [outcome.sse() for outcome in self.outcomes]
        
@cython.final
cdef class SingleOutcomeDependentData:
    def __init__(SingleOutcomeDependentData self, FLOAT_t[:] y, SingleWeightDependentData weight,
                 FLOAT_t[:] theta, FLOAT_t omega, INDEX_t m, INDEX_t k, INDEX_t max_terms):
        self.y = y
        self.weight = weight
        self.theta = theta
        self.omega = omega
        self.m = m
        self.k = k
        self.max_terms = max_terms
    
    @classmethod
    def alloc(cls, FLOAT_t[:] y, SingleWeightDependentData weight, INDEX_t m, INDEX_t max_terms):
        cdef FLOAT_t[:] theta
        cdef FLOAT_t[:] wy = np.empty(shape=m, dtype=np.float)
        cdef int i
        for i in range(m):
            wy[i] = weight.w[i] * y[i]
        cdef FLOAT_t omega = np.dot(wy, wy)
        theta = np.dot(weight.Q_t, wy)
        return cls(y, weight, theta, omega, m, 0, max_terms)
    
    cpdef FLOAT_t sse(SingleOutcomeDependentData self):
        '''
        Return the weighted mean squared error for the linear least squares problem
        represented by Q_t, y, and w.
        '''
        return ((self.omega - np.dot(self.theta, self.theta)) ** 2)# / np.sum(self.w)
    
#     cpdef int update_from_basis_function(OutcomeDependentData self, BasisFunction bf, FLOAT_t[:,:] X, 
#                                          BOOL_t[:,:] missing, FLOAT_t zero_tol) except *:
#         if self.k >= self.max_terms:
#             return -1
#         bf.apply(X, missing, self.Q_t[self.k, :])
#         return self._update(zero_tol)
#         
#     cpdef int update_from_array(OutcomeDependentData self, FLOAT_t[:] b, FLOAT_t zero_tol) except *:
#         if self.k >= self.max_terms:
#             return -1
#         
#         
#         cdef INDEX_t j
#         for j in range(self.m):
#             self.Q_t[self.k,j] = self.w[j] * b[j]
#         return self._update(zero_tol)
    cpdef int synchronize(SingleOutcomeDependentData self, FLOAT_t zero_tol) except *:
        self.k = self.weight.k
        self.theta = np.dot(self.weight.Q_t[:self.k, :], np.asarray(self.y) * self.weight.w)
        return 0
    
    cpdef int update(SingleOutcomeDependentData self, FLOAT_t zero_tol) except *:
        # Assume weight has already been updated.
        if self.k >= self.max_terms:
            return -1
        self.k += 1
        self.theta = np.dot(self.weight.Q_t[:self.k, :], np.asarray(self.y) * self.weight.w)
        
        return 0
        
    cpdef downdate(SingleOutcomeDependentData self):
        self.k -= 1
    
#     cpdef reweight(OutcomeDependentData self, FLOAT_t[:] w, FLOAT_t[:,:] B, INDEX_t k, FLOAT_t zero_tol):
#         cdef INDEX_t i
#         for weight in self.weights:
#             
#         self.w = w
#         self.k = 0
#         self.householder.reset()
#         for i in range(k):
#             self.update_from_array(B[:, i], zero_tol)
        

@cython.final
cdef class PredictorDependentData:
    def __init__(PredictorDependentData self, FLOAT_t[:] x,
                INT_t[:] order):
        self.x = x
        self.order = order
    
    def knot_candidates(PredictorDependentData self, cnp.ndarray[FLOAT_t, ndim = 1] p, int endspan, 
                        int minspan, FLOAT_t minspan_alpha, INDEX_t n, set knot_set):
        cdef INDEX_t minspan_, i, count, m, idx, countdown
        cdef FLOAT_t last, knot
        cdef bint first, skip
        cdef list candidates = []
        cdef list candidates_idx = []
        m = p.shape[0]
        count = 0
        for i in range(m):
            if p[i] != 0:
                count += 1
        
        if n * count == 0:
            return np.array(candidates, dtype=FLOAT), np.array(candidates_idx, dtype=INDEX)
        
        if minspan < 0:
            minspan_ =  <int> (-log2(-(1.0 / (n * count)) *
                                log(1.0 - minspan_alpha)) / 2.5)
        else:
            minspan_ = minspan

        i = endspan
        first = True
        skip = False
        countdown = 0
        while True:
            if m < endspan + i:
                break
            idx = self.order[i]
            knot = self.x[idx]
            if ((not first) and knot == last) or p[idx] == 0 or knot in knot_set:
                countdown = minspan_
                skip = True
                i += 1
            else:
                if first or knot != last:
                    last = knot
                    if countdown <= 0:
                        candidates.append(knot)
                        candidates_idx.append(idx)
                        countdown = minspan_
                    else:
                        countdown -= 1
                i += 1
            first = False
                
        return np.array(candidates, dtype=FLOAT), np.array(candidates_idx, dtype=INDEX)

    def ordered(self):
        return np.array(self.x)[self.order]
    
    @classmethod
    def alloc(cls, FLOAT_t[:] x):
        cdef INT_t[:] order
        order = np.argsort(x)[::-1]
        return cls(x, order)

@cython.final
cdef class KnotSearchReadOnlyData:
    def __init__(KnotSearchReadOnlyData self, PredictorDependentData predictor, MultipleOutcomeDependentData outcome):
        self.predictor = predictor
        self.outcome = outcome

#     @classmethod
#     def alloc(cls, FLOAT_t[:,:] Q_t, FLOAT_t[:] p, FLOAT_t[:] x, 
#               INDEX_t[:] order, FLOAT_t[:] y, 
#               FLOAT_t[:] w, int max_terms):
#         cdef int n_outcomes = y.shape[1]
#         cdef PredictorDependentData predictor = PredictorDependentData(p, x, 
#                                                         order)
#         cdef list outcomes = []
#         cdef int i
#         cdef MultipleOutcomeDependentDataoutcome = MultipleOutcomeDependentData.alloc():
#         for i in range(n_outcomes):
#             outcomes.append(OutcomeDependentData.alloc(y, w, max_terms))
#         return cls(predictor, outcomes)


@cython.final
cdef class KnotSearchState:
#     FLOAT_t alpha
#     FLOAT_t beta
#     FLOAT_t lambda_
#     FLOAT_t mu
#     FLOAT_t upsilon
#     FLOAT_t phi
#     FLOAT_t phi_next
#     INDEX_t ord_idx
#     INDEX_t idx
#     FLOAT_t zeta_squared
    def __init__(KnotSearchState self, FLOAT_t alpha, FLOAT_t beta, FLOAT_t lambda_, 
                 FLOAT_t mu, FLOAT_t upsilon, FLOAT_t phi, FLOAT_t phi_next, 
                 INDEX_t ord_idx, INDEX_t idx, FLOAT_t zeta_squared):
        self.alpha = alpha
        self.beta = beta
        self.lambda_ = lambda_
        self.mu = mu
        self.upsilon = upsilon
        self.phi = phi
        self.phi_next = phi_next
        self.ord_idx = ord_idx
        self.idx = idx
        self.zeta_squared = zeta_squared
        
    @classmethod
    def alloc(cls):
        return cls(0., 0., 0., 0., 0., 0., 0., 0, 0, 0.)

@cython.final
cdef class KnotSearchWorkingData:
    def __init__(KnotSearchWorkingData self, FLOAT_t[:] gamma, FLOAT_t[:] kappa,
                 FLOAT_t[:] delta_kappa, FLOAT_t[:] chi, FLOAT_t[:] psi,
                 KnotSearchState state):
        self.gamma = gamma
        self.kappa = kappa
        self.delta_kappa = delta_kappa
        self.chi = chi
        self.psi = psi
        self.state = state
    
    @classmethod
    def alloc(cls, int max_terms):
        cdef FLOAT_t[:] gamma = np.empty(shape=max_terms, dtype=np.float)
        cdef FLOAT_t[:] kappa = np.empty(shape=max_terms, dtype=np.float)
        cdef FLOAT_t[:] delta_kappa = np.empty(shape=max_terms, dtype=np.float)
        cdef FLOAT_t[:] chi = np.empty(shape=max_terms, dtype=np.float)
        cdef FLOAT_t[:] psi = np.empty(shape=max_terms, dtype=np.float)
        cdef INDEX_t q = 0
        cdef KnotSearchState state = KnotSearchState.alloc()
        return cls(gamma, kappa, delta_kappa, chi, psi, state)
    
@cython.final
cdef class KnotSearchData:
    def __init__(KnotSearchData self, KnotSearchReadOnlyData constant, 
                 list workings, INDEX_t q):
        self.constant = constant
        self.workings = workings
        self.q = q
        
cdef dot(FLOAT_t[:] x1, FLOAT_t[:] x2, INDEX_t q):
    cdef FLOAT_t result = 0.
    cdef INDEX_t i
    for i in range(q):
        result += x1[i] * x2[i]
    return result

cdef w2dot(FLOAT_t[:] w, FLOAT_t[:] x1, FLOAT_t[:] x2, INDEX_t q):
    cdef FLOAT_t result = 0.
    cdef INDEX_t i
    for i in range(q):
        result += (w[i] ** 2) * x1[i] * x2[i]
    return result

cdef wdot(FLOAT_t[:] w, FLOAT_t[:] x1, FLOAT_t[:] x2, INDEX_t q):
    cdef FLOAT_t result = 0.
    cdef INDEX_t i
    for i in range(q):
        result += w[i] * x1[i] * x2[i]
    return result

@cython.profile(False)
cdef void fast_update(PredictorDependentData predictor, SingleOutcomeDependentData outcome, 
                        KnotSearchWorkingData working, FLOAT_t[:] p, INDEX_t q, INDEX_t m, INDEX_t r) except *:
    
    # Calculate all quantities depending on the rows such that
    # phi >= x > phi_next.
    # Before this while loop, x[idx] is the greatest x such that x <= phi.
    # This while loop computes the quantities nu, xi, rho, sigma, tau,
    # chi, and psi.  It also computes the updates to kappa, lambda, mu,
    # and upsilon.  The latter updates should not be applied until after
    # alpha, beta, and gamma have been updated, as they apply to the
    # next iteration.
    cdef FLOAT_t epsilon_squared
    cdef INDEX_t idx, j
    cdef FLOAT_t nu = 0.
    cdef FLOAT_t xi = 0.
    cdef FLOAT_t rho = 0.
    cdef FLOAT_t sigma = 0.
    cdef FLOAT_t tau = 0.
    working.chi[:q] = 0.
    working.psi[:q] = 0.
    working.delta_kappa[:q] = 0.
    cdef FLOAT_t delta_lambda = 0.
    cdef FLOAT_t delta_mu = 0.
    cdef FLOAT_t delta_upsilon = 0.
    
    while predictor.x[working.state.idx] > working.state.phi_next:
        idx = working.state.idx
        
        # In predictor.x[idx] is missing, p[idx] will be zeroed out for protection
        # (because there will be a present(x[idx]) factor in it)..
        # Skipping such indices prevents problems if x[idx] is a nan of some kind.
        if p[idx] != 0.:
            nu += (outcome.weight.w[idx] ** 2) * (p[idx] ** 2)
            xi += (outcome.weight.w[idx] ** 2) * (p[idx] ** 2) * predictor.x[idx]
            rho += (outcome.weight.w[idx] ** 2) * (p[idx] ** 2) * (predictor.x[idx] ** 2)
            sigma += (outcome.weight.w[idx] ** 2) * outcome.y[idx] * p[idx] * predictor.x[idx]
            tau += (outcome.weight.w[idx] ** 2) * outcome.y[idx] * p[idx]
            delta_lambda += (outcome.weight.w[idx] ** 2) * (p[idx] ** 2) * predictor.x[idx]
            delta_mu += (outcome.weight.w[idx] ** 2) * (p[idx] ** 2)
            delta_upsilon += (outcome.weight.w[idx] ** 2) * outcome.y[idx] * p[idx]
            for j in range(q):
                working.chi[j] += outcome.weight.Q_t[j,idx] * outcome.weight.w[idx] * p[idx] * predictor.x[idx]
                working.psi[j] += outcome.weight.Q_t[j,idx] * outcome.weight.w[idx] * p[idx]
                working.delta_kappa[j] += outcome.weight.Q_t[j,idx] * outcome.weight.w[idx] * p[idx]
            
        # Update idx for next iteration
        working.state.ord_idx += 1
        if working.state.ord_idx >= m:
            break
        working.state.idx = predictor.order[working.state.ord_idx]

    # Update alpha, beta, and gamma
    working.state.alpha += sigma - working.state.phi_next * tau + \
        (working.state.phi - working.state.phi_next) * working.state.upsilon
    working.state.beta += rho + (working.state.phi_next ** 2) * nu - 2 * working.state.phi_next * xi + \
        2 * (working.state.phi - working.state.phi_next) * working.state.lambda_ + \
        (working.state.phi_next ** 2 - working.state.phi ** 2) * working.state.mu
    for j in range(q):
        working.gamma[j] += (working.state.phi - working.state.phi_next) * working.kappa[j] + \
                            working.chi[j] - working.state.phi_next * working.psi[j]
                            
#     x_should_be = np.maximum(np.asarray(predictor.x) - working.state.phi_next, 0) * p 
#     alpha_should_be = np.dot(x_should_be * outcome.weight.w, np.array(outcome.weight.w) * outcome.y)
#     print 'alpha = ', np.asarray(working.state.alpha), alpha_should_be
#     print 'beta =', np.asarray(working.state.beta), np.dot(x_should_be, x_should_be)
#     print 'gamma =', np.asarray(working.gamma[:q]), np.dot(outcome.weight.Q_t[:q,:], x_should_be)
    
    # Compute epsilon_squared and zeta_squared
    if working.state.beta > 0:
        epsilon_squared = working.state.beta 
        for j in range(q):
            epsilon_squared -= working.gamma[j] ** 2
        if epsilon_squared > 0:
            working.state.zeta_squared = (working.state.alpha - dot(working.gamma, outcome.theta, q)) ** 2
            working.state.zeta_squared /= epsilon_squared
        else:
            working.state.zeta_squared = 0.
    else:
        working.state.zeta_squared = 0.
    # Now zeta_squared is correct for phi_next.
    
    # Update kappa, lambda, mu, and upsilon
    for j in range(q):
        working.kappa[j] += working.delta_kappa[j]
    working.state.lambda_ += delta_lambda
    working.state.mu += delta_mu
    working.state.upsilon += delta_upsilon
    
cpdef tuple knot_search(KnotSearchData data, FLOAT_t[:] candidates, FLOAT_t[:] p, INDEX_t q, INDEX_t m, 
                 INDEX_t r, INDEX_t n_outcomes):
    cdef KnotSearchReadOnlyData constant = data.constant
    cdef PredictorDependentData predictor = constant.predictor
    cdef list outcomes = constant.outcome.outcomes
    cdef list workings = data.workings
    
    # TODO: Remove these assertions
    assert len(outcomes) == n_outcomes
    assert len(workings) == len(outcomes)
    assert len(candidates) == r
    assert outcomes[0].k == q
    
    # Initialize variables to their pre-loop values.  These are the values
    # they would have for a hypothetical knot candidate, phi, such that
    # phi > max(x).  This only matters for values that will be tracked and
    # updated across iterations.  Values that are calculated from scratch at
    # each iteration are not initialized.
    cdef FLOAT_t best_knot = 0.
    cdef INDEX_t best_knot_index = 0
    cdef FLOAT_t phi_next = candidates[0]
    cdef FLOAT_t phi
    cdef KnotSearchWorkingData working
    cdef INDEX_t j, i
#     print 'begin knot search!'
    for j in range(n_outcomes):
        working = workings[j]
        working.state.phi_next = phi_next
        working.state.alpha = 0.
        working.state.beta = 0.
        for i in range(q):
            working.gamma[i] = 0.
        for i in range(q):
            working.kappa[i] = 0.
        working.state.lambda_ = 0.
        working.state.mu = 0.
        working.state.upsilon = 0.
        working.state.ord_idx = 0
        working.state.idx = predictor.order[working.state.ord_idx]
    
    # A lower bound for zeta_squared is 0 (it is the square of a real number),
    # so initialize best_zeta_squared to 0.
    best_zeta_squared = 0.
    
    # Iterate over candidates.
    # Loop invariant: At the start (and end) of each iteration, alpha, beta,
    # and gamma are correct for the knot phi_next.  Kappa, lambda, mu, and
    # upsilon are correct for the update from (not to) phi_next.  That is,
    # alpha, beta, and gamma should be updated before kappa, lambda, mu,
    # and upsilon are updated.
    cdef SingleOutcomeDependentData outcome
    cdef FLOAT_t zeta_squared
    cdef INDEX_t k
    cdef FLOAT_t loss
    for k in range(r):
        phi = phi_next
        phi_next = candidates[k]
        zeta_squared = 0.
        for i in range(n_outcomes):
            working = workings[i]
            outcome = outcomes[i]
            
            # Get the next candidate knot
            working.state.phi = phi
            working.state.phi_next = phi_next
            
            # Update workingdata for the new candidate knot
            fast_update(predictor, outcome, working, p, q, m, r)
            
            # Add up objectives
            zeta_squared += working.state.zeta_squared

        # Compare against best result so far
        if zeta_squared > best_zeta_squared:
            best_knot_index = k
            best_knot = phi_next
            best_zeta_squared = zeta_squared
        
        # DEBUG
#         loss = -best_zeta_squared
#         for i in range(n_outcomes):
#             outcome = outcomes[i]
#             loss += outcome.omega - np.dot(outcome.theta[:q], outcome.theta[:q])
#         if loss < 0:
#             print 'negative loss!'
#             print 'best_zeta_squared =', best_zeta_squared
#             x_should_be = np.maximum(np.asarray(predictor.x) - best_knot, 0) * p 
#             
#             for i in range(n_outcomes):
#                 outcome = outcomes[i]
#                 print 'should be eye = ', np.dot(outcome.weight.Q_t[:q,:], np.transpose(outcome.weight.Q_t[:q,:]))
#                 omega_should_be = np.dot(np.array(outcome.weight.w) * outcome.y, np.array(outcome.weight.w) * outcome.y)
#                 theta_should_be = np.dot(outcome.weight.Q_t[:q,:], np.array(outcome.weight.w) * outcome.y)
#                 print 'omega =', outcome.omega, omega_should_be
#                 print 'theta =', np.array(outcome.theta[:q]), theta_should_be
#                 print 'theta^2 =', np.dot(outcome.theta[:q], outcome.theta[:q]), np.dot(theta_should_be, theta_should_be)
#             raise ValueError
        # END DEBUG
    # Calculate value of overall objective function
    # (this is the sqrt of the sum of squared residuals)
    loss = -best_zeta_squared
    for i in range(n_outcomes):
        outcome = outcomes[i]
        loss += outcome.omega - np.dot(outcome.theta[:q], outcome.theta[:q])
#     if loss < 0:
#         print 'negative loss!'
#         print 'best_zeta_squared =', best_zeta_squared
#         x_should_be = np.maximum(np.asarray(predictor.x) - best_knot, 0) * p 
#         
#         for i in range(n_outcomes):
#             outcome = outcomes[i]
#             
#             omega_should_be = np.dot(np.array(outcome.weight.w) * outcome.y, np.array(outcome.weight.w) * outcome.y)
#             theta_should_be = np.dot(outcome.weight.Q_t[:q,:], np.array(outcome.weight.w) * outcome.y)
#             print 'omega =', outcome.omega, omega_should_be
#             print 'theta =', np.array(outcome.theta[:q]), theta_should_be
#             print 'theta^2 =', np.dot(outcome.theta[:q], outcome.theta[:q]), np.dot(theta_should_be, theta_should_be)
#         raise ValueError
#     loss = sqrt(loss)
    
    # Return
    return best_knot, best_knot_index, loss


