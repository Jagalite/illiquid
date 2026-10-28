// Benchmark-only support compiled identically into both separate modules.
// No inlinable or transparent body is exported to the driver.
@inline(never)
func requestHDRIdentityCoordinates() -> [SIMD2<Float>] {
    PiPVideoMapping.identityTextureCoordinates
}
