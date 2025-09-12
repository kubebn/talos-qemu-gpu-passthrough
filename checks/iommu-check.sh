# Check for IOMMU enablement
IOMMU_GROUPS=$(find /sys/kernel/iommu_groups/ -type l | wc -l)
if [ "$IOMMU_GROUPS" -eq 0 ]; then
    echo "IOMMU is not enabled. Please ensure that IOMMU is enabled in your BIOS/UEFI settings."
    exit 1
else
    echo "IOMMU is enabled with $IOMMU_GROUPS groups."
fi