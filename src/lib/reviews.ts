export const reviewLabels: Record<number, string> = {
  10: 'Masterpiece', 9: 'Amazing', 8: 'Great', 7: 'Good', 6: 'Decent',
  5: 'Mixed', 4: 'Disappointing', 3: 'Bad', 2: 'Terrible', 1: 'Disaster',
};

export function reviewLabel(rating: number) {
  return reviewLabels[rating] || 'Unrated';
}

export function isReview(rating: number | undefined): rating is number {
  return typeof rating === 'number' && Number.isInteger(rating) && rating >= 1 && rating <= 10;
}

export function reviewTopicLabel(topic: string) {
  return topic === 'tv' ? 'TV & Streaming' : topic.charAt(0).toUpperCase() + topic.slice(1);
}
