import type { Results } from "../types";

export function RangeFlag({
  results,
  roiId,
}: {
  results: Results | null;
  roiId: number;
}) {
  const flag = results?.outside_calibration?.find((f) => f.roi_id === roiId);
  if (!flag) return null;
  return (
    <span
      className="range-flag"
      title="This ROI's calibrated color lies outside the calibration patch colors, so the calibration extrapolates."
    >
      Outside calibration range ({flag.channels.join(", ")})
    </span>
  );
}
