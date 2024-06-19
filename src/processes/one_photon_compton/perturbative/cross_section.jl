#####
# Perturbative one-photon Compton scattering
# Implementation of the cross section interface
#####

function _incident_flux(in_psp::InPhaseSpacePoint{<:Compton,<:PerturbativeQED})
    return momentum(in_psp, QEDbase.Incoming(), 1) * momentum(in_psp, QEDbase.Incoming(), 2)
end

function _matrix_element(psp::PhaseSpacePoint{<:Compton,PerturbativeQED})
    in_ps = momenta(psp, QEDbase.Incoming())
    out_ps = momenta(psp, QEDbase.Outgoing())
    return _pert_compton_matrix_element(psp.proc, in_ps, out_ps)
end

"""
    _averaging_norm(proc::Compton)

!!! note "Convention"

    We average over the initial spins and pols, and sum over final.
"""
function _averaging_norm(proc::Compton)
    normalizations = number_of_spin_pol.(_in_spin_and_pol(proc))
    return inv(prod(normalizations))
end

@inline function _all_onshell(psp::PhaseSpacePoint{<:Compton})
    return @inbounds isapprox(
            QEDbase.getMass2(momentum(psp, QEDbase.Incoming(), 1)),
            QEDbase.mass(incoming_particles(psp.proc)[1])^2,
        ) &&
        isapprox(
            QEDbase.getMass2(momentum(psp, QEDbase.Incoming(), 2)),
            QEDbase.mass(incoming_particles(psp.proc)[2])^2,
        ) &&
        isapprox(
            QEDbase.getMass2(momentum(psp, QEDbase.Outgoing(), 1)),
            QEDbase.mass(outgoing_particles(psp.proc)[1])^2,
        ) &&
        isapprox(
            QEDbase.getMass2(momentum(psp, QEDbase.Outgoing(), 2)),
            QEDbase.mass(outgoing_particles(psp.proc)[2])^2,
        )
end

@inline function _is_in_phasespace(psp::PhaseSpacePoint{<:Compton,<:PerturbativeQED})
    @inbounds if (
        !isapprox(
            momentum(psp, QEDbase.Incoming(), 1) + momentum(psp, QEDbase.Incoming(), 2),
            momentum(psp, QEDbase.Outgoing(), 1) + momentum(psp, QEDbase.Outgoing(), 2),
        )
    )
        return false
    end
    return _all_onshell(psp)
end

@inline function _phase_space_factor(psp::PhaseSpacePoint{<:Compton,PerturbativeQED})
    in_ps = momenta(psp, QEDbase.Incoming())
    out_ps = momenta(psp, QEDbase.Outgoing())
    return _pert_compton_ps_fac(psp.ps_def, in_ps[2], out_ps[2])
end

#######
# Matrix elements
#######

@inline function _pert_compton_matrix_element(
    proc::Compton, in_ps::NTuple{N,T}, out_ps::NTuple{M,T}
) where {N,M,T<:QEDbase.AbstractFourMomentum}
    in_electron_mom = in_ps[1]
    in_photon_mom = in_ps[2]
    out_electron_mom = out_ps[1]
    out_photon_mom = out_ps[2]

    in_electron_state = base_state(
        QEDbase.Electron(), QEDbase.Incoming(), in_electron_mom, proc.in_spin
    )
    in_photon_state = base_state(
        QEDbase.Photon(), QEDbase.Incoming(), in_photon_mom, proc.in_pol
    )

    out_electron_state = base_state(
        QEDbase.Electron(), QEDbase.Outgoing(), out_electron_mom, proc.out_spin
    )

    out_photon_state = base_state(
        QEDbase.Photon(), QEDbase.Outgoing(), out_photon_mom, proc.out_pol
    )
    return _pert_compton_matrix_element(
        in_electron_mom,
        in_electron_state,
        in_photon_mom,
        in_photon_state,
        out_electron_mom,
        out_electron_state,
        out_photon_mom,
        out_photon_state,
    )
end

function _pert_compton_matrix_element(
    in_electron_mom::T,
    in_electron_state,
    in_photon_mom::T,
    in_photon_state,
    out_electron_mom::T,
    out_electron_state,
    out_photon_mom::T,
    out_photon_state,
) where {T<:QEDbase.AbstractFourMomentum}
    base_states_comb = Iterators.product(
        QEDbase._as_svec(in_electron_state),
        QEDbase._as_svec(in_photon_state),
        QEDbase._as_svec(out_electron_state),
        QEDbase._as_svec(out_photon_state),
    )

    matrix_elements = Vector{ComplexF64}()
    sizehint!(matrix_elements, length(base_states_comb))
    for (in_el, in_ph, out_el, out_ph) in base_states_comb
        push!(
            matrix_elements,
            _pert_compton_matrix_element_single(
                in_electron_mom,
                in_el,
                in_photon_mom,
                in_ph,
                out_electron_mom,
                out_el,
                out_photon_mom,
                out_ph,
            ),
        )
    end

    return matrix_elements
end

function _pert_compton_matrix_element_single(
    in_electron_mom::T,
    in_electron_state::BiSpinor,
    in_photon_mom::T,
    in_photon_state::SLorentzVector,
    out_electron_mom::T,
    out_electron_state::AdjointBiSpinor,
    out_photon_mom::T,
    out_photon_state::SLorentzVector,
) where {T<:QEDbase.AbstractFourMomentum}
    in_ph_slashed = slashed(in_photon_state)
    out_ph_slashed = slashed(out_photon_state)

    prop1 = _fermion_propagator(in_photon_mom + in_electron_mom, mass(QEDbase.Electron()))
    prop2 = _fermion_propagator(in_electron_mom - out_photon_mom, mass(QEDbase.Electron()))

    # TODO: fermion propagator is not yet in QEDbase
    diagram_1 =
        out_electron_state *
        (out_ph_slashed * (prop1 * (in_ph_slashed * in_electron_state)))
    diagram_2 =
        out_electron_state *
        (in_ph_slashed * (prop2 * (out_ph_slashed * in_electron_state)))

    result = diagram_1 + diagram_2

    # TODO: find (preferably unitful) global provider for physical constants
    # elementary charge
    return ELEMENTARY_CHARGE_SQUARE * result
end

#######
# Phase space factors
#######

function _pert_compton_ps_fac(
    in_ps_def::PhasespaceDefinition{inCS,ElectronRestFrame}, in_photon_mom, out_photon_mom
) where {inCS}
    # TODO
    omega = QEDbase.getE(in_photon_mom)
    omega_prime = QEDbase.getE(out_photon_mom)
    return omega_prime^2 / (16 * pi^2 * omega * mass(QEDbase.Electron()))
end
