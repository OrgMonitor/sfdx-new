import { LightningElement, api } from 'lwc';

const RADIUS = 38;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export default class WizardSetupProgress extends LightningElement {
    @api currentStepIndex = 0;
    @api totalSteps = 5;
    @api completedSteps = 0;

    get circleCircumference() {
        return CIRCUMFERENCE.toFixed(2);
    }

    get progressPercent() {
        return Math.round((this.completedSteps / this.totalSteps) * 100);
    }

    get strokeDashoffset() {
        const filled = this.completedSteps / this.totalSteps;
        return (CIRCUMFERENCE * (1 - filled)).toFixed(2);
    }

    get currentStepDisplay() {
        return this.currentStepIndex + 1;
    }

    get progressAriaLabel() {
        return `Setup progress: step ${this.currentStepDisplay} of ${this.totalSteps}, ${this.progressPercent}% completed`;
    }
}