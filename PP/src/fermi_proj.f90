!
! Copyright (C) 2001-2016 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
!
! Usage :
! $ proj_fermi.x -in {input file}
! Then it generates proj.frmsf (for nspin = 1, 4) or
! proj1.frmsf and proj2.frmsf (for nspin = 2)
!
! Input file format (projwfc.x + tail):
! &PROJWFC
! prefix = "..."
! outdir = "..."
! ...
! /
! {Number of target WFCs}
! {Index of WFC1} {Index of WFC2} {Index of WFC3} ...
!
!-----------------------------------------------------------------------
MODULE fermi_proj_routines
!-----------------------------------------------------------------------
  !
  IMPLICIT NONE
  !
CONTAINS
  !
!-----------------------------------------------------------------------
SUBROUTINE read_projwfc(lbinary)
  !-----------------------------------------------------------------------
  !
  ! ... Read projwfc.x input file and use prefix, outdir, lbinary_data only.
  !
  USE io_files,  ONLY : prefix, tmp_dir
  USE io_global, ONLY : stdout, ionode, ionode_id
  USE mp_world,  ONLY : world_comm
  USE spin_orb,  ONLY : lforcet
  USE mp,        ONLY : mp_bcast
  USE kinds,     ONLY : DP
  USE klist,     ONLY : degauss, ngauss
  !
  IMPLICIT NONE
  !
  LOGICAL,INTENT(OUT) :: lbinary
  !
  CHARACTER(LEN=256), EXTERNAL :: trimcheck
  !
  CHARACTER (len=256) :: filpdos, filproj, outdir
  REAL (DP) :: Emin, Emax, DeltaE, degauss1, ef_0
  INTEGER :: ios
  LOGICAL :: lwrite_overlaps, lbinary_data
  LOGICAL :: lsym, kresolveddos, tdosinboxes, plotboxes, pawproj
  INTEGER, PARAMETER :: N_MAX_BOXES = 999
  INTEGER :: n_proj_boxes, irmin(3,N_MAX_BOXES), irmax(3,N_MAX_BOXES)
  LOGICAL :: lgww  !if .true. use GW QP energies from file bands.dat
  !
  ! Exact the same namelist to that of projwfc.x
  !
  NAMELIST / projwfc / outdir, prefix, ngauss, degauss, lsym, &
             Emin, Emax, DeltaE, filpdos, filproj, lgww, &
             kresolveddos, tdosinboxes, n_proj_boxes, irmin, irmax, plotboxes, &
             lwrite_overlaps, lbinary_data, pawproj, lforcet, ef_0
  !
  !   set default values for variables in namelist
  !
  prefix = 'pwscf'
  CALL get_environment_variable('ESPRESSO_TMPDIR', outdir)
  IF (TRIM(outdir) == ' ') outdir = './'
  lbinary_data = .FALSE.
  !
  ios = 0
  !

  lforcet = .FALSE.

  IF (ionode) THEN
     CALL input_from_file ()
     READ (5, projwfc, iostat = ios)
     tmp_dir = trimcheck (outdir)
  ENDIF
  !
  CALL mp_bcast (ios, ionode_id, world_comm)
  IF (ios /= 0) CALL errore ('do_projwfc', 'reading projwfc namelist', ABS(ios))
  !
  ! ... Broadcast variables (Only used ones)
  !
  CALL mp_bcast(tmp_dir,   ionode_id, world_comm)
  CALL mp_bcast(prefix,    ionode_id, world_comm)
  CALL mp_bcast(lbinary_data,    ionode_id, world_comm)
  CALL mp_bcast(lforcet, ionode_id, world_comm)
  !
  lbinary = lbinary_data
  !
END SUBROUTINE read_projwfc
!
!-----------------------------------------------------------------------
SUBROUTINE read_atomic_proj(lbinary_data, wt, ns, nk)
  !-----------------------------------------------------------------------
  !
  ! Read atomic_proj.* generated by projwfc.x
  !
  USE io_files,           ONLY : prefix, tmp_dir, postfix
  USE iotk_module
  USE basis,              ONLY : natomwfc
  USE wvfct,              ONLY : nbnd
  USE fermisurfer_common, ONLY : b_low, b_high
  USE io_global,          ONLY : stdout, ionode, ionode_id
  USE kinds,              ONLY : DP
  USE mp_world,           ONLY : world_comm
  USE mp,                 ONLY : mp_bcast
  !
  IMPLICIT NONE
  !
  INTEGER,INTENT(IN) :: nk, ns
  LOGICAL,INTENT(IN) :: lbinary_data
  REAL(DP),INTENT(OUT) :: wt(nbnd,nk,ns)
  !
  INTEGER :: iun, ik, ibnd, iwfc, ispin, ierr, nwfc, targetwfc(natomwfc)
  CHARACTER(256) :: tmp
  COMPLEX(DP) :: projs(nbnd,natomwfc)
  !
  INTEGER, EXTERNAL :: find_free_unit
  !
  ! Read target wavefunctions from the tail of the input file
  !
  IF (ionode) THEN
     READ(5,*) nwfc
     READ(5,*) targetwfc(1:nwfc)
  END IF
  CALL mp_bcast(nwfc,              ionode_id, world_comm)
  CALL mp_bcast(targetwfc(1:nwfc), ionode_id, world_comm)
  WRITE(stdout,'(5x,a, i6)') "Number of target wavefunction : ",  nwfc
  WRITE(stdout,'(5x,a, 1000i6)') "Target wavefunction : ", targetwfc(1:nwfc)
  !
  tmp = TRIM(tmp_dir) // TRIM(prefix) // postfix // 'atomic_proj'
  !
  IF (lbinary_data) THEN
     tmp = TRIM(tmp) // ".dat"
  ELSE
     tmp = TRIM(tmp) // ".xml"
  ENDIF
  !
  IF (ionode) THEN
     !
     iun = find_free_unit()
     CALL iotk_open_read(iun, FILE=TRIM(tmp), &
     &                    BINARY=lbinary_data, IERR=ierr)
     !
     ! Read projections
     !
     CALL iotk_scan_begin(iun,"PROJECTIONS")
     !
     DO ik = 1, nk
        !
        CALL iotk_scan_begin(iun,"K-POINT"//TRIM(iotk_index(ik)))
        !
        DO ispin = 1, ns
           !
           IF(ns == 2) CALL iotk_scan_begin(iun,"SPIN"//TRIM(iotk_index(ispin)))
           !
           DO iwfc = 1, natomwfc
              CALL iotk_scan_dat(iun,"ATMWFC"//TRIM(iotk_index(iwfc)), projs(1:nbnd,iwfc))
           END DO
           !
           ! Store Sum_{target tau l m n} |<n k|tau n m l>|^2 into wt(:,:,:)
           !
           DO ibnd = b_low, b_high
              wt(ibnd, ik, ispin) = SUM(REAL(CONJG(projs(ibnd, targetwfc(1:nwfc))) &
              &                                  * projs(ibnd, targetwfc(1:nwfc)), DP))
           END DO
           !
           IF(ns == 2) CALL iotk_scan_end(iun,"SPIN"//TRIM(iotk_index(ispin)))
           !
        END DO
        !
        CALL iotk_scan_end(iun,"K-POINT"//TRIM(iotk_index(ik)))
        !
     END DO
     !
     CALL iotk_scan_end(iun,"PROJECTIONS")
     !
     CALL iotk_close_read(iun)
     !
  END IF
  !
  CALL mp_bcast(wt, ionode_id, world_comm)
  !
END SUBROUTINE read_atomic_proj
!
END MODULE fermi_proj_routines
!
!----------------------------------------------------------------------------
PROGRAM fermi_proj
  !----------------------------------------------------------------------------
  !
  ! Usage :
  ! $ proj_fermi.x -in {input file}
  ! Then it generates proj.frmsf (for nspin = 1, 4) or
  ! proj1.frmsf and proj2.frmsf (for nspin = 2)
  !
  ! Input file format (projwfc.x + tail):
  ! &PROJWFC
  ! prefix = "..."
  ! outdir = "..."
  ! ...
  ! /
  ! {Number of target WFCs}
  ! {Index of WFC1} {Index of WFC2} {Index of WFC3} ...
  !
  USE mp_global,            ONLY : mp_startup
  USE environment,          ONLY : environment_start, environment_end
  USE kinds,                ONLY : DP
  USE wvfct,                ONLY : nbnd, et
  USE start_k,              ONLY : nk1, nk2, nk3
  USE lsda_mod,             ONLY : nspin
  USE ener,                 ONLY : ef, ef_up, ef_dw
  USE klist,                ONLY : nks, two_fermi_energies
  USE basis,                ONLY : natomwfc
  USE fermisurfer_common,   ONLY : b_low, b_high, rotate_k_fs, write_fermisurfer
  USE fermi_proj_routines,  ONLY : read_projwfc, read_atomic_proj
  !
  IMPLICIT NONE
  !
  INTEGER :: i1, i2, i3, ik, ibnd, ispin, ns, nk, ierr
  REAL(DP) :: ef1, ef2
  INTEGER,ALLOCATABLE :: equiv(:,:,:)
  REAL(DP),ALLOCATABLE :: eig(:,:,:,:,:), wfc(:,:,:,:,:), wt(:,:)
  LOGICAL :: lbinary_data
  !
  CHARACTER(LEN=256), EXTERNAL :: trimcheck
  !
  CALL mp_startup ()
  CALL environment_start ('FERMI_PROJ')
  !
  ! ... Read projwfc.x input file and get prefix, outdir, lbinary_data
  !
  CALL read_projwfc(lbinary_data)
  !
  ! ... Read XML file generated by pw.x
  !
  CALL read_xml_file()
  !
  ! ... Find equivalent k point in irr-BZ for whole BZ
  !
  ALLOCATE(equiv(nk1, nk2, nk3))
  CALL rotate_k_fs(equiv)
  !
  IF (nspin == 2) THEN
     ns = 2
     IF(two_fermi_energies) THEN
        ef1 = ef_up
        ef2 = ef_dw
     ELSE
        ef1 = ef
        ef2 = ef
     END IF
  ELSE
     ns = 1
  END IF
  nk = nks / ns
  !
  ! ... Read {prefix}.save/atomic_proj.* generated by projwfc.x
  !
  ALLOCATE(wt(nbnd,nks))
  CALL read_atomic_proj(lbinary_data, wt, ns, nk)
  !
  ALLOCATE(wfc(b_low:b_high, nk1, nk2, nk3, ns), &
  &        eig(b_low:b_high, nk1, nk2, nk3, ns))
  !
  ! ... Map e_k(Measured from E_F) and projected WFCs into whole BZ 
  !
  DO i3 = 1, nk3
     DO i2 = 1, nk2
        DO i1 = 1, nk1
           !
           IF(nspin == 2) THEN
              eig(b_low:b_high,i1,i2,i3,1) = et(b_low:b_high, equiv(i1,i2,i3)     ) - ef1
              eig(b_low:b_high,i1,i2,i3,2) = et(b_low:b_high, equiv(i1,i2,i3) + nk) - ef2
              wfc(b_low:b_high,i1,i2,i3,1) = wt(b_low:b_high, equiv(i1,i2,i3)     )
              wfc(b_low:b_high,i1,i2,i3,2) = wt(b_low:b_high, equiv(i1,i2,i3) + nk)
           ELSE
              eig(b_low:b_high,i1,i2,i3,1) = et(b_low:b_high, equiv(i1,i2,i3)     ) - ef
              wfc(b_low:b_high,i1,i2,i3,1) = wt(b_low:b_high, equiv(i1,i2,i3)     )
           END IF
           !
        END DO ! i1 = 1, nk1
     END DO ! i2 = 1, nk2
  END DO ! i3 = 1, nk3
  !
  ! ... Output in the FermiSurfer format
  !
  IF (nspin == 2) THEN
     CALL write_fermisurfer(eig(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 1), &
     &                      wfc(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 1), "proj1.frmsf")
     CALL write_fermisurfer(eig(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 2), &
     &                      wfc(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 2), "proj2.frmsf")
  ELSE
     CALL write_fermisurfer(eig(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 1), &
     &                      wfc(b_low:b_high, 1:nk1, 1:nk2, 1:nk3, 1), "proj.frmsf")
  END IF
  !
  DEALLOCATE(eig, equiv, wfc, wt)
  !
  CALL environment_end ('FERMI_PROJ')
  CALL stop_pp
  !
END PROGRAM fermi_proj
