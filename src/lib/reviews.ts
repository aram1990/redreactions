export function reviewLabel(rating: number) {
  if (rating === 10) return 'Masterpiece';
  if (rating >= 9 && rating < 10) return 'Amazing';
  if (rating >= 8 && rating < 9) return 'Great';
  if (rating >= 7 && rating < 8) return 'Good';
  if (rating >= 6 && rating < 7) return 'Decent';
  if (rating >= 5 && rating < 6) return 'Mixed';
  if (rating >= 4 && rating < 5) return 'Disappointing';
  if (rating >= 3 && rating < 4) return 'Bad';
  if (rating >= 2 && rating < 3) return 'Terrible';
  if (rating >= 1 && rating < 2) return 'Disaster';
  return 'Unrated';
}

export function isReview(rating: number | undefined): rating is number {
  return typeof rating === 'number' && Number.isFinite(rating) && rating >= 1 && rating <= 10;
}

export function reviewTopicLabel(topic: string) {
  return topic === 'tv' ? 'TV & Streaming' : topic.charAt(0).toUpperCase() + topic.slice(1);
}
