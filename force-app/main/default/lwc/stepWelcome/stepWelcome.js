import { LightningElement } from 'lwc';

export default class StepWelcome extends LightningElement {
    benefits = [
        { id: 'b1', label: 'Detect and alert on unauthorised configuration changes' },
        { id: 'b2', label: 'Enforce deployment windows and release compliance' },
        { id: 'b3', label: 'Filter out CI/CD noise so you focus on real violations' },
        { id: 'b4', label: 'Maintain a full audit trail for security and compliance reviews' },
    ];
}