//! Bounded native E2E: only the fixture created by this test may be touched.
use driftwm_macos_backend::{FixtureSession, OutputPlacement, Transform, validate_placements};

#[test]
fn invalid_placements_cannot_change_a_real_fixture() -> Result<(), Box<dyn std::error::Error>> {
    let mut fixture = FixtureSession::spawn()?;
    let before = fixture.snapshot()?;
    for matrix in [[0.0; 6], [f64::NAN; 6], [f64::INFINITY; 6]] {
        let placement = OutputPlacement {
            output_id: 1,
            transform: Transform(matrix),
            clip: None,
        };
        assert!(
            fixture
                .with_placement(&placement, |_| -> driftwm_macos_backend::Result<()> {
                    panic!("invalid placement reached callback")
                })
                .is_err()
        );
    }
    let placement = OutputPlacement {
        output_id: 1,
        transform: before.transform.clone(),
        clip: None,
    };
    assert!(validate_placements(&[placement.clone(), placement.clone()]).is_err());
    let clipped = OutputPlacement {
        clip: Some([0.0, 0.0, 10.0, 10.0]),
        ..placement
    };
    assert!(
        fixture
            .with_placement(&clipped, |_| -> driftwm_macos_backend::Result<()> {
                panic!("unsupported clip reached callback")
            })
            .is_err()
    );
    let mut stale = before.identity.clone();
    stale.process_start[1] += 1;
    assert!(driftwm_macos_backend::snapshot_window(&stale).is_err());
    let after = fixture.snapshot()?;
    assert_eq!(before.transform, after.transform);
    assert_eq!(before.bounds, after.bounds);
    drop(fixture);
    assert!(driftwm_macos_backend::snapshot_window(&before.identity).is_err());
    Ok(())
}
