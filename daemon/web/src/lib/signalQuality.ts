export interface SignalQuality {
    timestamp: number;
    serving_cell: ServingCell;
    neighbour_cells: NeighbourCell[];
}

export interface ServingCell {
    state: string;
    tech: string;
    duplex: string;
    mcc: string;
    mnc: string;
    cell_id: string;
    pci: number;
    earfcn: number;
    band: number;
    rsrp: number;
    rsrq: number;
    rssi: number;
    sinr: number;
}

export interface NeighbourCell {
    type: string;
    earfcn: number;
    pci: number;
    rsrq: number;
    rsrp: number;
    rssi: number;
}

export type SignalLevel = 'Excellent' | 'Good' | 'Fair' | 'Poor' | 'No Signal';

export function getSignalLevel(rsrp: number): SignalLevel {
    if (rsrp > -80) return 'Excellent';
    if (rsrp > -90) return 'Good';
    if (rsrp > -100) return 'Fair';
    if (rsrp > -110) return 'Poor';
    return 'No Signal';
}

export function getSignalBars(rsrp: number): number {
    if (rsrp > -80) return 4;
    if (rsrp > -90) return 3;
    if (rsrp > -100) return 2;
    if (rsrp > -110) return 1;
    return 0;
}

export function getSignalColor(rsrp: number): string {
    if (rsrp > -90) return '#22c55e'; // green-500
    if (rsrp > -100) return '#eab308'; // yellow-500
    if (rsrp > -110) return '#f97316'; // orange-500
    return '#ef4444'; // red-500
}
