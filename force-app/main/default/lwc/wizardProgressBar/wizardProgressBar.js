import { LightningElement, api } from 'lwc';

export default class WizardProgressBar extends LightningElement {
    @api steps = [];
    @api currentStepIndex = 0;

    get displaySteps() {
        const total = this.steps.length;
        return this.steps.map((step, idx) => {
            const isCompleted = ['Configured', 'Skipped', 'Complete'].includes(step.configStatus);
            const isCurrent = idx === this.currentStepIndex;
            const isFirst = idx === 0;
            const isLast = idx === total - 1;

            return {
                ...step,
                index: idx,
                isCompleted,
                isCurrent,
                liClass: 'wpb-item',
                circleClass: `wpb-circle${isCompleted ? ' wpb-circle--completed' : ''}${isCurrent ? ' wpb-circle--current' : ''}`,
                labelClass: `wpb-label${isCurrent ? ' wpb-label--current' : ''}${isCompleted ? ' wpb-label--completed' : ''}`,
                leftLineClass: `wpb-line${isFirst ? ' wpb-line--hidden' : ''}${(isCompleted || isCurrent) ? ' wpb-line--active' : ''}`,
                rightLineClass: `wpb-line${isLast ? ' wpb-line--hidden' : ''}${isCompleted ? ' wpb-line--active' : ''}`,
                ariaCurrent: isCurrent ? 'step' : null,
                ariaLabel: `Step ${step.number} of ${total}: ${step.label}${isCompleted ? ', completed' : isCurrent ? ', current' : ''}`,
            };
        });
    }
}